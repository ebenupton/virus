; game.s — Real-time perspective grid with camera translation for BBC Micro
; Assembled with ca65: ca65 --cpu 65C02 game.s -o game.o
; Linked with ld65:    ld65 -C linker.cfg game.o -o game.bin
;
; Loads and runs at $0800. Double-buffered at $3000/$5800 (10K each).
; MODE 2-like video: 128x160, 4bpp, 512-byte stripes.
; XOR rendering for flicker-free erase/redraw.
;
; Parameterisable grid centred on camera tile, projected in real time each frame.
; Height modulation from 32×32 toroidal heightmap (5-bit height, 3-bit colour).

.setcpu "65C02"
.segment "CODE"

; === MOS entry points (RTS stubs in emulator) ===
OSWRCH      = $FFEE
OSBYTE      = $FFF4

; === Hardware registers ===
CRTC_REG    = $FE00
CRTC_DAT    = $FE01
SYS_VIA_IFR = $FE4D
SYS_VIA_DDRA = $FE43
SYS_VIA_ORA  = $FE4F

.include "raster_zp.inc"
.include "math_zp.inc"

; === Zero page: state ===
back_buf_idx    = $8A       ; 0 or 1
frame_count     = $8C
lfsr_state      = $9C       ; 8-bit LFSR for random colours

; === Zero page: camera state ===
cam_x_lo        = $85       ; 8.8 fixed-point X position (low byte)
cam_x_hi        = $86       ; 8.8 fixed-point X position (high byte)
cam_z_lo        = $87       ; 8.8 fixed-point Z position (low byte)
cam_z_hi        = $88       ; 8.8 fixed-point Z position (high byte)

; === Zero page: projection workspace ===
v_ptr           = $78       ; 2 bytes — V buffer write pointer
hmap_ptr        = $7A       ; 2 bytes — heightmap row pointer
proj_col        = $7C       ; inner loop counter (vertices remaining)
hmap_col        = $7D       ; current heightmap column index (0..31)
z_cam_lo        = $7E       ; z_cam low byte (8.8 fractional part, running)
z_cam_hi        = $7F       ; z_cam high byte (8.8 integer part, running)

; Reuse grid_ptr as h_ptr during projection
h_ptr           = $94       ; 2 bytes (same as grid_ptr)

proj_row        = $A0       ; outer loop counter (row index)
recip_val       = $A1       ; recip for current row (≈ 64/z_cam)
step_lo         = $A2       ; x step low byte (recip * 64, fractional)
step_hi         = $A3       ; x step high byte (recip * 64, integer)
base_x          = $A4       ; heightmap column base for column 0
run_lo          = $A5       ; sx running accumulator low byte
run_hi          = $A6       ; sx running accumulator high byte
sy_val          = $A7       ; sy for current row (constant per row)
base_z          = $A8       ; heightmap row base for row 0

; === Zero page: draw_grid state ===
grid_ptr        = $94       ; 2 bytes — pointer into chain data
grid_count      = $96       ; chains remaining
seg_count       = $97       ; segments remaining in current chain
chain_idx       = $98       ; byte offset within current chain
saved_y         = $99       ; saved sub-row Y during chain iteration
saved_color     = $9A       ; colour for current chain (draw_chains)
clamp_x         = $9A       ; clamped sx for column 0 (project_grid, $FF=none)
chain_segs      = $A9       ; segments per chain (for draw_chains)
chain_stride    = $AA       ; bytes per chain (for draw_chains)

; === Constants ===
SCREEN_W    = 128            ; pixels wide (4bpp, 2 pixels per byte)
SCREEN_H    = 160            ; pixels tall (20 character rows)

; Buffer addresses (in RAM below code segment)
h_buf       = $0300          ; GRID_VTX_Z horizontal chains (H_CHAIN_BYTES each), row-major
v_buf       = $0400          ; GRID_VTX_X vertical chains (V_CHAIN_BYTES each), column-major
; BBC Micro key scan codes
KEY_Z       = $61
KEY_X       = $42
KEY_RETURN  = $49
KEY_SPACE   = $62

; Grid dimensions (cells, not vertices)
GRID_COLS   = 8              ; cells across (X direction)
GRID_ROWS   = 8              ; cells down (Z direction)
GRID_VTX_X  = GRID_COLS + 1  ; vertices per row
GRID_VTX_Z  = GRID_ROWS + 1  ; vertices per column (= number of rows)
HALF_COLS   = GRID_COLS / 2   ; half-width in cells
HALF_ROWS   = GRID_ROWS / 2   ; half-depth in cells
H_CHAIN_BYTES = GRID_VTX_X * 3 ; bytes per horizontal chain
V_CHAIN_BYTES = GRID_VTX_Z * 3 ; bytes per vertical chain

; Camera constants
CAM_SPEED   = $08            ; ~0.03 units/frame in 8.8 (quarter-scale grid)


; =====================================================================
; Entry point ($0800)
; =====================================================================

entry:
    SEI

    ; CRTC: 64 byte-columns (128 pixels at 4bpp), screen at $3000
    LDA #1
    STA CRTC_REG
    LDA #64
    STA CRTC_DAT

    LDA #12
    STA CRTC_REG
    LDA #$06
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #$00
    STA CRTC_DAT

    ; Clear both screen buffers
    LDA #$30
    STA screen_page
    JSR clear_screen
    LDA #$58
    STA screen_page
    JSR clear_screen

    ; Initialize state
    LDA #0
    STA back_buf_idx
    STA frame_count

    ; Seed LFSR for random line colours
    LDA #$A7
    STA lfsr_state

    ; Back buffer = buffer 1 ($5800)
    LDA #$58
    STA screen_page
    LDA #1
    STA back_buf_idx

    ; Initialize camera: x=0, z=-2.25 (8.8 fixed-point, $FDC0)
    STZ cam_x_lo
    STZ cam_x_hi
    LDA #$C0
    STA cam_z_lo
    LDA #$FD
    STA cam_z_hi

; =====================================================================
; Main loop
; =====================================================================

main_loop:
    JSR update_camera
    JSR clear_screen
    JSR project_grid
    JSR draw_grid
    JSR wait_vsync
    JSR flip_buffers
    JMP main_loop

; =====================================================================
; VSync and buffer flip
; =====================================================================

wait_vsync:
    LDA #0
    STA frame_count
@vs_loop:
    LDA SYS_VIA_IFR
    AND #$02
    BEQ @vs_loop
    LDA #$02
    STA SYS_VIA_IFR
    INC frame_count
    LDA frame_count
    CMP #2
    BCC @vs_loop
    RTS

flip_buffers:
    LDA back_buf_idx
    BNE @show_buf1

    ; Show buffer 0 ($3000): R12=$06
    LDA #12
    STA CRTC_REG
    LDA #$06
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #$00
    STA CRTC_DAT
    LDA #$58
    STA screen_page
    LDA #1
    STA back_buf_idx
    RTS

@show_buf1:
    ; Show buffer 1 ($5800): R12=$0B
    LDA #12
    STA CRTC_REG
    LDA #$0B
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #$00
    STA CRTC_DAT
    LDA #$30
    STA screen_page
    LDA #0
    STA back_buf_idx
    RTS

; =====================================================================
; Update camera — VIA key scanning, direct X/Z translation
; =====================================================================

update_camera:
    LDA #$7F
    STA SYS_VIA_DDRA        ; bits 0-6 output, bit 7 input

    ; Z key → move left (cam_x -= SPEED)
    LDA #KEY_Z
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_left
    LDA cam_x_lo
    SEC
    SBC #CAM_SPEED
    STA cam_x_lo
    LDA cam_x_hi
    SBC #0
    STA cam_x_hi
@no_left:

    ; X key → move right (cam_x += SPEED)
    LDA #KEY_X
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_right
    LDA cam_x_lo
    CLC
    ADC #CAM_SPEED
    STA cam_x_lo
    LDA cam_x_hi
    ADC #0
    STA cam_x_hi
@no_right:

    ; Return → move forward (cam_z += SPEED)
    LDA #KEY_RETURN
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_forward
    LDA cam_z_lo
    CLC
    ADC #CAM_SPEED
    STA cam_z_lo
    LDA cam_z_hi
    ADC #0
    STA cam_z_hi
@no_forward:

    ; Space → move backward (cam_z -= SPEED)
    LDA #KEY_SPACE
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_back
    LDA cam_z_lo
    SEC
    SBC #CAM_SPEED
    STA cam_z_lo
    LDA cam_z_hi
    SBC #0
    STA cam_z_hi
@no_back:
    RTS

; =====================================================================
; Clear back buffer — 40 unrolled STZ abs,X (~52K cycles)
; =====================================================================

clear_screen:
    LDA screen_page
    CMP #$58
    BEQ clear_buf1

clear_buf0:
    LDX #0
@loop:
    STZ $3000,X
    STZ $3100,X
    STZ $3200,X
    STZ $3300,X
    STZ $3400,X
    STZ $3500,X
    STZ $3600,X
    STZ $3700,X
    STZ $3800,X
    STZ $3900,X
    STZ $3A00,X
    STZ $3B00,X
    STZ $3C00,X
    STZ $3D00,X
    STZ $3E00,X
    STZ $3F00,X
    STZ $4000,X
    STZ $4100,X
    STZ $4200,X
    STZ $4300,X
    STZ $4400,X
    STZ $4500,X
    STZ $4600,X
    STZ $4700,X
    STZ $4800,X
    STZ $4900,X
    STZ $4A00,X
    STZ $4B00,X
    STZ $4C00,X
    STZ $4D00,X
    STZ $4E00,X
    STZ $4F00,X
    STZ $5000,X
    STZ $5100,X
    STZ $5200,X
    STZ $5300,X
    STZ $5400,X
    STZ $5500,X
    STZ $5600,X
    STZ $5700,X
    INX
    BNE @loop
    RTS

clear_buf1:
    LDX #0
@loop:
    STZ $5800,X
    STZ $5900,X
    STZ $5A00,X
    STZ $5B00,X
    STZ $5C00,X
    STZ $5D00,X
    STZ $5E00,X
    STZ $5F00,X
    STZ $6000,X
    STZ $6100,X
    STZ $6200,X
    STZ $6300,X
    STZ $6400,X
    STZ $6500,X
    STZ $6600,X
    STZ $6700,X
    STZ $6800,X
    STZ $6900,X
    STZ $6A00,X
    STZ $6B00,X
    STZ $6C00,X
    STZ $6D00,X
    STZ $6E00,X
    STZ $6F00,X
    STZ $7000,X
    STZ $7100,X
    STZ $7200,X
    STZ $7300,X
    STZ $7400,X
    STZ $7500,X
    STZ $7600,X
    STZ $7700,X
    STZ $7800,X
    STZ $7900,X
    STZ $7A00,X
    STZ $7B00,X
    STZ $7C00,X
    STZ $7D00,X
    STZ $7E00,X
    STZ $7F00,X
    INX
    BNE @loop
    RTS

; =====================================================================
; Project grid — perspective projection of GRID_VTX_X × GRID_VTX_Z grid
; =====================================================================
;
; Grid: GRID_COLS × GRID_ROWS cells, 0.25-unit spacing, centred on camera.
; Camera: (cam_x, -1.5, cam_z) — cam_y constant, no yaw.
; Projection: vx = 64·x_cam/z_cam, vy = 64·y_cam/z_cam,
;             screen centre (64, 80).
;
; Per-row: one urecip15 call gives recip ≈ 64/z_cam.
; sy_val = base sy from camera height (constant per row).
; Per-vertex height modulation: Δsy = h*recip/32 via umul8x8(h*8, recip).hi.
; sx advances by a constant step = recip·0.25 per vertex (16-bit add).

project_grid:
    ; === Compute z_cam for row 0 ===
    ; sub_z = cam_z_lo & $3F (0..63).  When sub_z >= $20 (half cell),
    ; snap: increment cell_z, reverse offset → grid displaces ±half cell max.
    LDA cam_z_lo
    AND #$3F                  ; sub_z (0..63)
    CMP #$20
    BCS @z_wrap
    ; sub_z < $20: z_cam = (HALF_ROWS+1)*$40 - sub_z
    STA temp2
    SEC
    LDA #<((HALF_ROWS + 1) * $40)
    SBC temp2
    STA z_cam_lo
    LDA #>((HALF_ROWS + 1) * $40)
    SBC #0
    STA z_cam_hi
    BRA @z_done
@z_wrap:
    ; sub_z >= $20: z_cam = (HALF_ROWS+2)*$40 - sub_z
    STA temp2
    SEC
    LDA #<((HALF_ROWS + 2) * $40)
    SBC temp2
    STA z_cam_lo
    LDA #>((HALF_ROWS + 2) * $40)
    SBC #0
    STA z_cam_hi
@z_done:

    ; === Compute heightmap base indices ===
    ; cell = cam >> 6, then +1 if sub-cell >= $20 (half-cell snap).
    ; base = cell - 4.

    ; base_x
    LDA cam_x_lo
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                     ; cam_x_lo >> 6 (0..3)
    STA temp2
    LDA cam_x_hi
    ASL A
    ASL A                     ; cam_x_hi * 4
    CLC
    ADC temp2
    SEC
    SBC #HALF_COLS
    STA base_x
    ; +1 if sub_x >= $20
    LDA cam_x_lo
    AND #$3F
    CMP #$20
    BCC @bx_done
    INC base_x
@bx_done:

    ; base_z
    LDA cam_z_lo
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                     ; cam_z_lo >> 6 (0..3)
    STA temp2
    LDA cam_z_hi
    ASL A
    ASL A                     ; cam_z_hi * 4
    CLC
    ADC temp2
    SEC
    SBC #HALF_ROWS
    STA base_z
    ; +1 if sub_z >= $20
    LDA cam_z_lo
    AND #$3F
    CMP #$20
    BCC @bz_done
    INC base_z
@bz_done:

    ; === Initialize h_ptr ===
    LDA #<h_buf
    STA h_ptr
    LDA #>h_buf
    STA h_ptr+1

    ; === Row loop: j = 0..8 ===
    STZ proj_row

@row_loop:
    ; --- Skip if z_cam <= 0 (behind or on camera plane) ---
    LDA z_cam_hi
    BMI @do_skip              ; negative → behind camera
    ORA z_cam_lo
    BNE @z_cam_ok             ; non-zero positive → proceed
@do_skip:
    JMP @skip_row
@z_cam_ok:

    ; --- Reciprocal: recip = urecip15(z_cam << 2) ≈ 64/z_cam ---
    LDA z_cam_lo
    ASL A
    STA math_b
    LDA z_cam_hi
    ROL A
    ASL math_b
    ROL A
    STA math_a
    JSR urecip15
    LDA math_res_lo           ; recip fits in low byte for our z range
    STA recip_val

    ; --- sy = 80 + recip * 3/2 (= 80 + 96/z_cam, from cam_y = -1.5) ---
    LSR A                     ; recip >> 1
    CLC
    ADC recip_val             ; recip + recip/2 = recip * 1.5
    BCS @sy_clamp             ; overflow → clamp
    CLC
    ADC #80
    BCS @sy_clamp             ; overflow → clamp
    CMP #160
    BCC @sy_ok
@sy_clamp:
    LDA #159
@sy_ok:
    STA sy_val

    ; --- Step = recip * 64 (16-bit), the screen-x increment per cell ---
    ; recip_val:$00 = recip * 256 = step * 4, so step = recip_val:$00 >> 2
    LDA recip_val
    LSR A
    LSR A                     ; step_hi = recip >> 2
    STA step_hi
    LDA recip_val
    AND #$03
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A                     ; step_lo = (recip & 3) << 6
    STA step_lo

    ; --- sx_running = $4000 - HALF_COLS*step ± sub_x*recip ---
    ; Subtract step from $4000 HALF_COLS times (16-bit fixed-point)
    STZ run_lo
    LDA #64
    STA run_hi
    LDX #HALF_COLS
@sub_step:
    LDA run_lo
    SEC
    SBC step_lo
    STA run_lo
    LDA run_hi
    SBC step_hi
    STA run_hi
    DEX
    BNE @sub_step
    LDA #$FF
    STA clamp_x               ; default: no clamp

    LDA cam_x_lo
    AND #$3F                  ; sub_x (0..63)
    CMP #$20
    BCS @x_wrap
    ; sub_x < $20: subtract sub_x * recip
    BEQ @cam_x_done           ; sub_x = 0 → no offset
    STA math_a
    LDA recip_val
    STA math_b
    JSR umul8x8
    ; Clamped column 0: sx = (64-recip) + math_res_hi (x_cam = sub_x - $100)
    LDA #64
    SEC
    SBC recip_val
    CLC
    ADC math_res_hi
    BMI @clamp_col0_ok
    CMP #128
    BCC @clamp_col0_ok
    LDA #127
@clamp_col0_ok:
    STA clamp_x
    ; Normal sx_running: subtract sub_x * recip
    LDA run_lo
    SEC
    SBC math_res_lo
    STA run_lo
    LDA run_hi
    SBC math_res_hi
    STA run_hi
    BRA @cam_x_done
@x_wrap:
    ; sub_x >= $20: add ($40 - sub_x) * recip
    EOR #$3F
    INC A                     ; A = $40 - sub_x (1..$20)
    STA math_a
    LDA recip_val
    STA math_b
    JSR umul8x8
    LDA run_lo
    CLC
    ADC math_res_lo
    STA run_lo
    LDA run_hi
    ADC math_res_hi
    STA run_hi
@cam_x_done:

    ; --- Heightmap row pointer for this row ---
    ; hmap_z = (base_z + proj_row) & 31
    LDA base_z
    CLC
    ADC proj_row
    AND #$1F
    ; hmap_ptr = height_map + hmap_z * 32
    TAX
    LSR A
    LSR A
    LSR A                     ; hmap_z >> 3
    CLC
    ADC #>height_map
    STA hmap_ptr+1
    TXA
    AND #$07
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A                     ; (hmap_z & 7) << 5
    CLC
    ADC #<height_map
    STA hmap_ptr
    BCC @no_hmap_carry
    INC hmap_ptr+1
@no_hmap_carry:

    ; Reset heightmap column for this row
    LDA base_x
    AND #$1F
    STA hmap_col

    ; --- Init v_ptr for this row ---
    ; v_ptr = v_buf + proj_row * 3
    LDA proj_row
    ASL A
    CLC
    ADC proj_row              ; A = proj_row * 3
    CLC
    ADC #<v_buf
    STA v_ptr
    LDA #>v_buf
    STA v_ptr+1

    ; --- Column loop: GRID_VTX_X vertices ---
    LDA #GRID_VTX_X
    STA proj_col

@col_loop:
    ; --- Height lookup and sy adjustment ---
    LDY hmap_col
    LDA (hmap_ptr),Y
    STA div_tmp1              ; save full byte for color extraction
    AND #$1F                  ; height 0..31
    BEQ @use_sy_val           ; flat → use row's base sy

    ; Δsy = hi_byte(h*8 * recip) = h * recip / 32
    ASL A
    ASL A
    ASL A                     ; h * 8 (max 248, fits in byte)
    STA math_a
    LDA recip_val
    STA math_b
    JSR umul8x8
    ; sy_vertex = sy_val - Δsy, clamp to 0
    LDA sy_val
    SEC
    SBC math_res_hi
    BCS @sy_vert_ok
    LDA #0                    ; underflow → clamp to 0
@sy_vert_ok:
    BRA @sy_vert_done

@use_sy_val:
    LDA sy_val

@sy_vert_done:
    STA temp2                 ; save adjusted sy

    ; --- sx = clamp(run_hi, 0, 127) ---
    LDA run_hi
    BMI @clamp_lo
    CMP #128
    BCC @sx_ok
    LDA #127
    BRA @sx_ok
@clamp_lo:
    LDA #0
@sx_ok:
    ; Override column 0 with clamped x (left edge stays near grid edge)
    LDX proj_col
    CPX #GRID_VTX_X           ; first column?
    BNE @no_clamp_x
    LDX clamp_x
    BMI @no_clamp_x           ; $FF = no clamp (bit 7 set)
    TXA
@no_clamp_x:
    ; Store (sx, sy, color) to h_buf and v_buf
    LDY #0
    STA (h_ptr),Y
    STA (v_ptr),Y
    INY
    LDA temp2
    STA (h_ptr),Y
    STA (v_ptr),Y
    ; Extract colour from heightmap byte (top 3 bits → 0..7)
    LDA div_tmp1
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    TAX
    LDA color_unpack,X
    LDY #2
    STA (h_ptr),Y
    STA (v_ptr),Y

    ; Advance heightmap column
    LDA hmap_col
    INC A
    AND #$1F
    STA hmap_col

    ; Advance: h_ptr += 3, v_ptr += V_CHAIN_BYTES
    LDA h_ptr
    CLC
    ADC #3
    STA h_ptr
    LDA v_ptr
    CLC
    ADC #V_CHAIN_BYTES
    STA v_ptr
    BCC @no_vpc
    INC v_ptr+1
@no_vpc:

    ; sx_running += step
    LDA run_lo
    CLC
    ADC step_lo
    STA run_lo
    LDA run_hi
    ADC step_hi
    STA run_hi

    DEC proj_col
    BEQ @col_done
    JMP @col_loop
@col_done:
    BRA @next_row

@skip_row:
    ; Fill GRID_VTX_X vertices at (64, 159, black) for behind-camera rows
    ; Using y=159 (screen bottom) prevents XOR artifacts in vertical chains
    ; h_buf: sequential write (3 bytes per vertex)
    LDY #0
    LDX #GRID_VTX_X
@skip_h:
    LDA #64
    STA (h_ptr),Y
    INY
    LDA #159
    STA (h_ptr),Y
    INY
    LDA #0                    ; black colour
    STA (h_ptr),Y
    INY
    DEX
    BNE @skip_h
    ; Advance h_ptr past this row
    LDA h_ptr
    CLC
    ADC #H_CHAIN_BYTES
    STA h_ptr

    ; v_buf: stride V_CHAIN_BYTES per column (forward row order)
    LDA proj_row
    ASL A
    CLC
    ADC proj_row              ; proj_row * 3
    CLC
    ADC #<v_buf
    STA v_ptr
    LDA #>v_buf
    STA v_ptr+1
    LDX #GRID_VTX_X
@skip_v:
    LDY #0
    LDA #64
    STA (v_ptr),Y
    INY
    LDA #159
    STA (v_ptr),Y
    INY
    LDA #0                    ; black colour
    STA (v_ptr),Y
    ; advance v_ptr by V_CHAIN_BYTES
    LDA v_ptr
    CLC
    ADC #V_CHAIN_BYTES
    STA v_ptr
    BCC @no_skip_vpc
    INC v_ptr+1
@no_skip_vpc:
    DEX
    BNE @skip_v

@next_row:
    ; z_cam += 64 ($0040 = 0.25 units in 8.8)
    LDA z_cam_lo
    CLC
    ADC #$40
    STA z_cam_lo
    LDA z_cam_hi
    ADC #0
    STA z_cam_hi

    INC proj_row
    LDA proj_row
    CMP #GRID_VTX_Z
    BCS @proj_done
    JMP @row_loop
@proj_done:
    RTS

; =====================================================================
; Draw perspective grid — horizontal + vertical chains
; =====================================================================

draw_grid:
    ; Draw GRID_VTX_Z horizontal chains from h_buf
    LDA #<h_buf
    STA grid_ptr
    LDA #>h_buf
    STA grid_ptr+1
    LDA #GRID_VTX_Z
    STA grid_count
    LDA #GRID_COLS
    STA chain_segs
    LDA #H_CHAIN_BYTES
    STA chain_stride
    JSR draw_chains

    ; Draw GRID_VTX_X vertical chains from v_buf
    LDA #<v_buf
    STA grid_ptr
    LDA #>v_buf
    STA grid_ptr+1
    LDA #GRID_VTX_X
    STA grid_count
    LDA #GRID_ROWS
    STA chain_segs
    LDA #V_CHAIN_BYTES
    STA chain_stride
    JMP draw_chains            ; tail call

draw_chains:
@chain_loop:
    ; Load first point of chain
    LDY #0
    LDA (grid_ptr),Y
    STA x0
    INY
    LDA (grid_ptr),Y
    STA y0
    JSR init_base           ; set base, mask_zp, Y for start point
    LDA #3
    STA chain_idx
    LDA chain_segs
    STA seg_count

@seg_loop:
    ; Save sub-row Y from previous segment / init_base
    STY saved_y
    ; Load colour for this segment (at startpoint's colour byte)
    LDY chain_idx
    DEY                     ; chain_idx - 1 = colour offset
    LDA (grid_ptr),Y
    STA saved_color
    INY
    ; Load next endpoint
    LDA (grid_ptr),Y
    STA x1
    INY
    LDA (grid_ptr),Y
    STA y1
    INY
    INY                     ; skip endpoint's colour byte
    STY chain_idx
    ; Restore sub-row Y before draw_line
    LDY saved_y
    LDA saved_color
    JSR draw_line           ; draw segment, chaining state
    ; Endpoint becomes start of next segment
    LDA x1
    STA x0
    LDA y1
    STA y0
    DEC seg_count
    BNE @seg_loop

    ; Draw final pixel of chain
    LDA x0
    LSR A                   ; bit 0 → carry
    LDA (base),Y
    BCS @right_final
    AND #$D5
    ORA color_left
    BRA @store_final
@right_final:
    AND #$EA
    ORA color_right
@store_final:
    STA (base),Y

    ; Advance to next chain
    LDA grid_ptr
    CLC
    ADC chain_stride
    STA grid_ptr
    BCC @no_carry
    INC grid_ptr+1
@no_carry:
    DEC grid_count
    BNE @chain_loop
    RTS

; ── Colour unpack table: 3-bit packed → MODE 2 right-pixel (bits 4,2,0) ──
; 0=black, 1=blue, 2=cyan, 3=green, 4=yellow, 5=red, 6=magenta, 7=white
color_unpack:
    .byte $00, $10, $14, $04, $05, $01, $11, $15

; =====================================================================
; Lookup tables and shared modules
; =====================================================================

.include "tables.inc"
.include "map_data.inc"
.include "math.s"
.include "raster.s"
