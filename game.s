; game.s — Battlezone-style wireframe 3D game for BBC Micro
; Assembled with ca65: ca65 --cpu 65C02 game.s -o game.o
; Linked with ld65:    ld65 -C linker.cfg game.o -o game.bin
;
; Loads and runs at $2000. Double-buffered at $4000/$6000.
; XOR rendering for flicker-free erase/redraw.

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
KEY_Z        = $61
KEY_X        = $42
KEY_RETURN   = $49

; === Zero page: rasterizer ($70-$84) ===
base            = $70       ; 2 bytes
delta_minor     = $72
delta_major     = $73
mask_zp         = $74
cols_left       = $75
stripes_left    = $75
final_branch    = $76
final_bias      = $76
x0              = $80
y0              = $81
x1              = $82
y1              = $83
screen_page     = $84

; === Zero page: game state ($85-$A5) ===
player_angle    = $85       ; 0-255 (256 = full rotation)
player_x_lo     = $86       ; 8.8 fixed point
player_x_hi     = $87
player_z_lo     = $88
player_z_hi     = $89
back_buf_idx    = $8A       ; 0 or 1
num_new_lines   = $8B
frame_count     = $8C

; Math workspace
math_a          = $8D       ; multiplier (signed 8-bit)
math_b          = $8E       ; multiplicand (signed 8-bit)
math_res_lo     = $8F       ; result low byte
math_res_hi     = $90       ; result high byte
temp0           = $91       ; rotated center X (signed)
temp1           = $92       ; rotated center Z (signed)
temp2           = $93       ; general temp / recip value
temp3           = $94       ; half-size h
face_vis        = $95       ; face visibility bitmask
cur_obj         = $96
num_objects     = $97

; Projection workspace
vx_temp         = $98       ; per-vertex view X
vz_temp         = $99       ; per-vertex view Z
base_y_temp     = $9A       ; computed base screen Y
recip_val       = $9B       ; recip_table[vz] for current vertex
obj_height      = $9C       ; object height H
num_lines_0      = $9D       ; prev line count for buffer 0
num_lines_1      = $9E       ; prev line count for buffer 1
rel_x           = $9F       ; relative world X (pre-rotation)
rel_z           = $A0       ; relative world Z (pre-rotation)

; Projection precision
recip_lo_val    = $A4       ; fractional recip correction for current vertex
center_vx_frac  = $A5       ; fractional center view X (0.8 format)
rot_hx_frac     = $A6       ; fractional h*cos corner offset
rot_kx_frac     = $A7       ; fractional h*sin corner offset
vx_frac         = $A8       ; per-vertex fractional X (passed to projection)
center_vz_frac  = $A9       ; fractional center view Z (0.8 format)
z_delta         = $AA       ; (unused, kept for clipper alias)
rot_hz_frac     = $AB       ; fractional part of rot_hz (8.8 negation)
vz_frac         = $AC       ; per-vertex fractional view Z
recip_shift     = $AD       ; 0, 1, or 2: post-multiply right-shift for extended recip range

; Rotation results
rot_hx          = $A1       ; (h * cos) >> 7
rot_kx          = $A2       ; (h * sin) >> 7
rot_hz          = $A3       ; -(h * sin) >> 7

; Clipper workspace (reuses projection temps, safe during emit_edge)
clip_x0_lo      = $98       ; = vx_temp
clip_x0_hi      = $99       ; = vz_temp
clip_x1_lo      = $9A       ; = base_y_temp
clip_x1_hi      = $9B       ; = recip_val
clip_y0         = $A4       ; = recip_lo_val
clip_y1         = $A5       ; = center_vx_frac
clip_dx_lo      = $A6       ; = rot_hx_frac
clip_dx_hi      = $A7       ; = rot_kx_frac
clip_num_lo     = $A8       ; = vx_frac
clip_num_hi     = $A9       ; = center_vz_frac
clip_ratio      = $AA       ; = z_delta
clip_y0_hi      = $AB       ; = rot_hz_frac (dead during clipper)
clip_y1_hi      = $AC       ; = vz_frac (dead during clipper)
clip_boundary   = $91       ; = temp0 (dead during clipper)

; === RAM buffers ($0200-$03FF) ===
; Projected vertex buffer (8 max per object, overwritten each object)
proj_x          = $0200     ; 8 bytes: projected screen X (lo byte)
proj_x_hi       = $0208     ; 8 bytes: projected screen X (hi byte, 0=on-screen)
proj_y          = $0210     ; 8 bytes: projected screen Y (lo byte)
proj_z          = $0218     ; 8 bytes: view-space Z (0 = invalid)
proj_y_hi       = $0220     ; 8 bytes: projected screen Y (hi byte, sign)

; Line buffers (4 bytes per line: x0, y0, x1, y1)
; Each screen buffer has its own line buffer; erase old, build new, draw new in place
lines_0         = $0228     ; buffer 0 lines (256 bytes) → $0228-$0327
lines_1         = $0328     ; buffer 1 lines (256 bytes) → $0328-$0427

; === Opcodes for self-modifying code ===
opLSRzp     = $46
opASLzp     = $06
opBCC       = $90
opNOP       = $EA
opBBR0      = $0F
opBBR1      = $1F
opBBR2      = $2F
opBBR3      = $3F
opBBR4      = $4F
opBBR5      = $5F
opBBR6      = $6F
opBBR7      = $7F

; === Constants ===
HORIZON_Y   = 128
CAMERA_Y    = 3             ; camera height above ground plane

; =====================================================================
; Entry point ($3000)
; =====================================================================

entry:
    SEI

    ; CRTC: 32 chars wide (256 pixels), screen at $4000
    LDA #1
    STA CRTC_REG
    LDA #32
    STA CRTC_DAT

    LDA #12
    STA CRTC_REG
    LDA #$08
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #$00
    STA CRTC_DAT

    ; Clear both screen buffers ($4000-$7FFF)
    LDA #0
    TAY
    LDX #$40
    STX base+1
    STY base
@clear_page:
    STA (base),Y
    INY
    BNE @clear_page
    INC base+1
    LDX base+1
    CPX #$80
    BNE @clear_page

    ; Initialize game state
    LDA #0
    STA player_angle
    STA player_x_lo
    STA player_z_lo
    STA back_buf_idx
    STA frame_count
    STA num_lines_0
    STA num_lines_1
    STA num_new_lines

    ; Player starts at (128, 64) — in middle X, behind objects
    LDA #128
    STA player_x_hi
    LDA #64
    STA player_z_hi

    LDA #NUM_OBJECTS
    STA num_objects

    ; Draw static HUD (horizon + crosshair) into both buffers
    LDA #$40
    STA screen_page
    JSR draw_static_hud
    LDA #$60
    STA screen_page
    JSR draw_static_hud

    ; Back buffer = buffer 1 ($6000)
    LDA #$60
    STA screen_page
    LDA #1
    STA back_buf_idx

; =====================================================================
; Main loop
; =====================================================================

main_loop:
    JSR read_input
    JSR erase_lines
    JSR build_scene
    JSR draw_lines
    JSR wait_vsync
    JSR flip_buffers
    JMP main_loop

; =====================================================================
; Input handling
; =====================================================================

read_input:
    LDA #$7F
    STA SYS_VIA_DDRA       ; bits 0-6 output, bit 7 input

    LDA #KEY_Z
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_left            ; bit 7 set = not pressed
    LDA player_angle
    CLC
    ADC #2
    STA player_angle
@no_left:

    LDA #KEY_X
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_right
    LDA player_angle
    SEC
    SBC #2
    STA player_angle
@no_right:

    LDA #KEY_RETURN
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_forward
    JSR move_forward
@no_forward:
    RTS

move_forward:
    LDX player_angle

    ; X movement: subtract sin(angle) >> 1 from 8.8 fixed point position
    ; Camera forward is (-sin(θ), cos(θ)) in world space
    LDA sin_table,X
    CMP #$80            ; set carry if negative (arithmetic shift right)
    ROR A               ; A = sin/2 (signed)
    STA temp2           ; save sin/2
    LDA player_x_lo
    SEC
    SBC temp2
    STA player_x_lo
    ; Sign-extend: if sin was negative, subtract $FF from hi byte (= add 1)
    LDA player_x_hi
    SBC #0              ; propagate borrow
    LDY sin_table,X
    BPL @sin_pos
    INC A               ; sign extension for negative sin (subtracting $FF = +1)
@sin_pos:
    STA player_x_hi

    ; Z movement: cos(angle) >> 1
    LDA cos_table,X
    CMP #$80
    ROR A
    CLC
    ADC player_z_lo
    STA player_z_lo
    LDA player_z_hi
    ADC #0
    LDY cos_table,X
    BPL @cos_pos
    DEC A
@cos_pos:
    STA player_z_hi
    RTS

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

    ; Show buffer 0: R12=$08
    LDA #12
    STA CRTC_REG
    LDA #$08
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #$00
    STA CRTC_DAT
    LDA #$60
    STA screen_page
    LDA #1
    STA back_buf_idx
    RTS

@show_buf1:
    ; Show buffer 1: R12=$0C
    LDA #12
    STA CRTC_REG
    LDA #$0C
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #$00
    STA CRTC_DAT
    LDA #$40
    STA screen_page
    LDA #0
    STA back_buf_idx
    RTS

; =====================================================================
; Line erase/draw/save
; =====================================================================

erase_lines:
    LDA back_buf_idx
    BNE @erase_buf1

    LDX num_lines_0
    BEQ @erase_done
    LDY #0
@erase_loop_0:
    LDA lines_0,Y
    STA x0
    LDA lines_0+1,Y
    STA y0
    LDA lines_0+2,Y
    STA x1
    LDA lines_0+3,Y
    STA y1
    PHX
    PHY
    JSR draw_line
    PLY
    PLX
    INY
    INY
    INY
    INY
    DEX
    BNE @erase_loop_0
    BRA @erase_done

@erase_buf1:
    LDX num_lines_1
    BEQ @erase_done
    LDY #0
@erase_loop_1:
    LDA lines_1,Y
    STA x0
    LDA lines_1+1,Y
    STA y0
    LDA lines_1+2,Y
    STA x1
    LDA lines_1+3,Y
    STA y1
    PHX
    PHY
    JSR draw_line
    PLY
    PLX
    INY
    INY
    INY
    INY
    DEX
    BNE @erase_loop_1

@erase_done:
    RTS

draw_lines:
    LDA back_buf_idx
    BNE @draw_buf1

    LDX num_lines_0
    BEQ @draw_done
    LDY #0
@draw_loop_0:
    LDA lines_0,Y
    STA x0
    LDA lines_0+1,Y
    STA y0
    LDA lines_0+2,Y
    STA x1
    LDA lines_0+3,Y
    STA y1
    PHX
    PHY
    JSR draw_line
    PLY
    PLX
    INY
    INY
    INY
    INY
    DEX
    BNE @draw_loop_0
    BRA @draw_done

@draw_buf1:
    LDX num_lines_1
    BEQ @draw_done
    LDY #0
@draw_loop_1:
    LDA lines_1,Y
    STA x0
    LDA lines_1+1,Y
    STA y0
    LDA lines_1+2,Y
    STA x1
    LDA lines_1+3,Y
    STA y1
    PHX
    PHY
    JSR draw_line
    PLY
    PLX
    INY
    INY
    INY
    INY
    DEX
    BNE @draw_loop_1

@draw_done:
    RTS

; =====================================================================
; Scene building
; =====================================================================

build_scene:
    LDA #0
    STA num_new_lines

    ; Patch emit_edge store addresses for current back buffer
    LDA back_buf_idx
    BEQ @patch_buf0
    LDA #>lines_1
    BRA @do_patch
@patch_buf0:
    LDA #>lines_0
@do_patch:
    STA ee_store_x0+2
    STA ee_store_y0+2
    STA ee_store_x1+2
    STA ee_store_y1+2

    ; Process each object
    LDA #0
    STA cur_obj
@obj_loop:
    LDA cur_obj
    CMP num_objects
    BCS @obj_done
    JSR process_object
    INC cur_obj
    BRA @obj_loop
@obj_done:
    ; Save line count for this buffer
    LDA back_buf_idx
    BNE @save_count_1
    LDA num_new_lines
    STA num_lines_0
    RTS
@save_count_1:
    LDA num_new_lines
    STA num_lines_1
    RTS

; draw_static_hud: Draw horizon + crosshair into current screen buffer
; Called once per buffer at init. Reads screen_page.
draw_static_hud:
    ; Horizon: (0, 128) to (255, 128)
    STZ x0
    LDA #HORIZON_Y
    STA y0
    LDA #255
    STA x1
    LDA #HORIZON_Y
    STA y1
    JSR draw_line

    ; Crosshair horizontal: (124, 128) to (132, 128)
    LDA #124
    STA x0
    LDA #HORIZON_Y
    STA y0
    LDA #132
    STA x1
    LDA #HORIZON_Y
    STA y1
    JSR draw_line

    ; Crosshair vertical: (128, 124) to (128, 132)
    LDA #128
    STA x0
    LDA #(HORIZON_Y - 4)
    STA y0
    LDA #128
    STA x1
    LDA #(HORIZON_Y + 4)
    STA y1
    JSR draw_line
    RTS

; =====================================================================
; Process one object
; =====================================================================

process_object:
    ; Load object data
    LDA cur_obj
    ASL A
    ASL A
    ASL A           ; * 8
    TAX

    LDA obj_table,X
    STA rel_x           ; world X
    LDA obj_table+1,X
    STA rel_z           ; world Z
    LDA obj_table+2,X
    PHA                 ; save type on stack
    LDA obj_table+3,X
    STA temp3           ; half-size h
    LDA obj_table+4,X
    STA obj_height      ; height H

    ; Translate: relative = world - player
    LDA rel_x
    SEC
    SBC player_x_hi
    STA rel_x           ; signed relative X

    LDA rel_z
    SEC
    SBC player_z_hi
    STA rel_z           ; signed relative Z

    ; Rotate by -player_angle:
    ;   view_x = (rel_x * cos + rel_z * sin) >> 7  (16-bit precision)
    ;   view_z = (-rel_x * sin + rel_z * cos) >> 7
    ;
    ; view_x uses full 16-bit products to preserve fractional bits.
    ; view_z stays 8-bit (Z quantization corrected by recip_lo table).

    LDY player_angle

    ; --- view_x = (rel_x * cos + rel_z * sin) >> 7 (16-bit) ---
    LDA rel_x
    STA math_a
    LDA cos_table,Y
    STA math_b
    JSR smul8x8         ; A = math_res_hi
    PHA                 ; save term1 hi
    LDA math_res_lo
    PHA                 ; save term1 lo

    LDA rel_z
    STA math_a
    LDA sin_table,Y
    STA math_b
    JSR smul8x8         ; full 16-bit: math_res_hi:math_res_lo

    ; 16-bit add: term1 + term2
    PLA                 ; term1 lo
    CLC
    ADC math_res_lo
    STA math_res_lo
    PLA                 ; term1 hi
    ADC math_res_hi
    ; A = sum hi, math_res_lo = sum lo

    ; Manual >>7: ASL lo, ROL hi
    ASL math_res_lo
    ROL A
    STA temp0           ; integer part of view_x
    LDA math_res_lo
    STA center_vx_frac  ; fractional part (0.8)

    ; --- view_z = (rel_z * cos - rel_x * sin) >> 7 (16-bit) ---
    LDA rel_z
    STA math_a
    LDA cos_table,Y
    STA math_b
    JSR smul8x8         ; A = math_res_hi
    PHA                 ; term1 hi
    LDA math_res_lo
    PHA                 ; term1 lo

    LDA rel_x
    STA math_a
    LDA sin_table,Y
    STA math_b
    JSR smul8x8         ; full 16-bit

    ; 16-bit subtract: term1 - term2
    PLA                 ; term1 lo
    SEC
    SBC math_res_lo
    STA math_res_lo
    PLA                 ; term1 hi
    SBC math_res_hi
    ; A = diff hi, math_res_lo = diff lo

    ; Manual >>7: ASL lo, ROL hi
    ASL math_res_lo
    ROL A
    PHA                 ; save integer view_z
    LDA math_res_lo
    STA center_vz_frac  ; fractional part
    PLA                 ; restore A = integer view_z (PLA sets N flag)
    STA temp1

    ; --- Sub-pixel position correction ---
    ; rel_x/rel_z only use player_x_hi/player_z_hi (integer).
    ; Correct view_x and view_z for the fractional player_x_lo/player_z_lo.
    ; Correction = -(player_?_lo * trig) / 32768, applied per-term via >>7.
    ; smul8x8 treats both args as signed; unsigned fixup adds trig to hi byte
    ; if player_?_lo >= 128. Y = player_angle preserved through smul8x8.

    ; == subtract (player_x_lo * cos) >> 7 from view_x ==
    LDA player_x_lo
    STA math_a
    LDA cos_table,Y
    STA math_b
    JSR smul8x8
    LDA player_x_lo
    BPL @sp1_ok
    CLC
    LDA math_res_hi
    ADC cos_table,Y
    STA math_res_hi
@sp1_ok:
    ASL math_res_lo
    ROL math_res_hi         ; carry = sign of correction
    BCC @sp1_pos
    LDX #$FF                ; negative → integer part = -1
    BRA @sp1_sub
@sp1_pos:
    LDX #0                  ; positive → integer part = 0
@sp1_sub:
    LDA center_vx_frac
    SEC
    SBC math_res_hi
    STA center_vx_frac
    TXA                     ; doesn't affect carry
    STA math_a
    LDA temp0
    SBC math_a
    STA temp0

    ; == subtract (player_z_lo * sin) >> 7 from view_x ==
    LDA player_z_lo
    STA math_a
    LDA sin_table,Y
    STA math_b
    JSR smul8x8
    LDA player_z_lo
    BPL @sp2_ok
    CLC
    LDA math_res_hi
    ADC sin_table,Y
    STA math_res_hi
@sp2_ok:
    ASL math_res_lo
    ROL math_res_hi
    BCC @sp2_pos
    LDX #$FF
    BRA @sp2_sub
@sp2_pos:
    LDX #0
@sp2_sub:
    LDA center_vx_frac
    SEC
    SBC math_res_hi
    STA center_vx_frac
    TXA
    STA math_a
    LDA temp0
    SBC math_a
    STA temp0

    ; == subtract (player_z_lo * cos) >> 7 from view_z ==
    LDA player_z_lo
    STA math_a
    LDA cos_table,Y
    STA math_b
    JSR smul8x8
    LDA player_z_lo
    BPL @sp3_ok
    CLC
    LDA math_res_hi
    ADC cos_table,Y
    STA math_res_hi
@sp3_ok:
    ASL math_res_lo
    ROL math_res_hi
    BCC @sp3_pos
    LDX #$FF
    BRA @sp3_sub
@sp3_pos:
    LDX #0
@sp3_sub:
    LDA center_vz_frac
    SEC
    SBC math_res_hi
    STA center_vz_frac
    TXA
    STA math_a
    LDA temp1
    SBC math_a
    STA temp1

    ; == add (player_x_lo * sin) >> 7 to view_z ==
    ; (view_z = rel_z*cos - rel_x*sin; correction subtracts both player terms,
    ;  so the -rel_x*sin term becomes +player_x_lo*sin)
    LDA player_x_lo
    STA math_a
    LDA sin_table,Y
    STA math_b
    JSR smul8x8
    LDA player_x_lo
    BPL @sp4_ok
    CLC
    LDA math_res_hi
    ADC sin_table,Y
    STA math_res_hi
@sp4_ok:
    ASL math_res_lo
    ROL math_res_hi
    BCC @sp4_pos
    LDX #$FF
    BRA @sp4_add
@sp4_pos:
    LDX #0
@sp4_add:
    LDA center_vz_frac
    CLC
    ADC math_res_hi
    STA center_vz_frac
    TXA
    STA math_a
    LDA temp1
    ADC math_a
    STA temp1

    ; Reload corrected view_z for the bounds check
    LDA temp1

    ; Check if object is in front of camera (Z >= 3)
    BMI @obj_behind      ; negative Z → behind camera
    CMP #3
    BCS @obj_in_front
@obj_behind:
    PLA                  ; discard type from stack
    RTS
@obj_in_front:

    ; Face visibility computed per-object type using screen-space winding
    LDA #0
    STA face_vis

    ; Dispatch by type
    PLA                  ; A = type
    BNE @do_pyramid
    JMP process_cube
@do_pyramid:
    JMP process_pyramid

; =====================================================================
; Process cube
; temp0 = center view X, temp1 = center view Z
; temp3 = half-size h, obj_height = H
; =====================================================================

process_cube:
    ; face_vis already has side faces from process_object
    ; Add top face if camera is above the object
    LDA #CAMERA_Y
    CMP obj_height      ; top visible only if camera >= object height
    BCC @no_top
    LDA face_vis
    ORA #$10
    STA face_vis
@no_top:

    ; --- Compute rotated corner offsets ---
    ; rot_hx = (h * cos) >> 7,  rot_kx = (h * sin) >> 7
    ; rot_hz = -(h * sin) >> 7 = -rot_kx
    ; (rot_kz = rot_hx, by symmetry)

    LDY player_angle

    LDA temp3
    STA math_a
    LDA cos_table,Y
    STA math_b
    JSR smul8x8         ; A = math_res_hi
    ASL math_res_lo
    ROL A
    STA rot_hx          ; h*cos >> 7 (also used as rot_kz)
    LDA math_res_lo
    STA rot_hx_frac     ; fractional part

    LDA temp3
    STA math_a
    LDA sin_table,Y
    STA math_b
    JSR smul8x8         ; A = math_res_hi
    ASL math_res_lo
    ROL A
    STA rot_kx          ; h*sin >> 7
    LDA math_res_lo
    STA rot_kx_frac     ; fractional part
    ; 8.8 negation: rot_hz:rot_hz_frac = -rot_kx:rot_kx_frac
    LDA #0
    SEC
    SBC rot_kx_frac
    STA rot_hz_frac
    LDA #0
    SBC rot_kx
    STA rot_hz          ; includes borrow from frac

    ; --- Project 8 vertices (4 bottom + 4 top) ---
    ; Corner 0: (-h, -h) → center + (-rot_hx - rot_kx, -rot_hz - rot_hx)
    ; 16-bit vx: frac then int, chaining borrow
    SEC
    LDA center_vx_frac
    SBC rot_hx_frac
    STA vx_frac
    LDA temp0
    SBC rot_hx
    TAY                  ; save intermediate int
    LDA vx_frac
    SEC
    SBC rot_kx_frac
    STA vx_frac
    TYA
    SBC rot_kx
    STA vx_temp
    ; Fractional VZ for corner 0
    LDA center_vz_frac
    SEC
    SBC rot_hz_frac
    STA temp2            ; intermediate frac
    LDA temp1
    SBC rot_hz
    TAY                  ; intermediate int
    LDA temp2
    SEC
    SBC rot_hx_frac      ; rot_kz_frac = rot_hx_frac
    STA vz_frac
    TYA
    SBC rot_hx           ; rot_kz = rot_hx
    STA vz_temp
    LDX #0               ; base vertex
    LDY #4               ; top vertex
    JSR project_corner

    ; Corner 1: (+h, -h) → center + (+rot_hx - rot_kx, +rot_hz - rot_hx)
    CLC
    LDA center_vx_frac
    ADC rot_hx_frac
    STA vx_frac
    LDA temp0
    ADC rot_hx
    TAY
    LDA vx_frac
    SEC
    SBC rot_kx_frac
    STA vx_frac
    TYA
    SBC rot_kx
    STA vx_temp
    ; Fractional VZ for corner 1
    LDA center_vz_frac
    CLC
    ADC rot_hz_frac
    STA temp2
    LDA temp1
    ADC rot_hz
    TAY
    LDA temp2
    SEC
    SBC rot_hx_frac
    STA vz_frac
    TYA
    SBC rot_hx
    STA vz_temp
    LDX #1
    LDY #5
    JSR project_corner

    ; Corner 2: (+h, +h) → center + (+rot_hx + rot_kx, +rot_hz + rot_hx)
    CLC
    LDA center_vx_frac
    ADC rot_hx_frac
    STA vx_frac
    LDA temp0
    ADC rot_hx
    TAY
    LDA vx_frac
    CLC
    ADC rot_kx_frac
    STA vx_frac
    TYA
    ADC rot_kx
    STA vx_temp
    ; Fractional VZ for corner 2
    LDA center_vz_frac
    CLC
    ADC rot_hz_frac
    STA temp2
    LDA temp1
    ADC rot_hz
    TAY
    LDA temp2
    CLC
    ADC rot_hx_frac
    STA vz_frac
    TYA
    ADC rot_hx
    STA vz_temp
    LDX #2
    LDY #6
    JSR project_corner

    ; Corner 3: (-h, +h) → center + (-rot_hx + rot_kx, -rot_hz + rot_hx)
    SEC
    LDA center_vx_frac
    SBC rot_hx_frac
    STA vx_frac
    LDA temp0
    SBC rot_hx
    TAY
    LDA vx_frac
    CLC
    ADC rot_kx_frac
    STA vx_frac
    TYA
    ADC rot_kx
    STA vx_temp
    ; Fractional VZ for corner 3
    LDA center_vz_frac
    SEC
    SBC rot_hz_frac
    STA temp2
    LDA temp1
    SBC rot_hz
    TAY
    LDA temp2
    CLC
    ADC rot_hx_frac
    STA vz_frac
    TYA
    ADC rot_hx
    STA vz_temp
    LDX #3
    LDY #7
    JSR project_corner

    ; --- Screen-space face culling (8-bit quantized, strict >) ---
    ; Both on-screen (hi=0): 8-bit strict > rejects edge-on at pixel resolution.
    ; Either off-screen: 16-bit >= (correct winding, edge-on impossible).

    ; Face 0 (+Z front): visible if proj_x[v3] > proj_x[v2]
    LDA proj_z + 3
    BEQ @face0_vis
    LDA proj_z + 2
    BEQ @face0_vis
    LDA proj_x_hi + 3
    ORA proj_x_hi + 2
    BEQ @f0_8bit
    SEC
    LDA proj_x + 3
    SBC proj_x + 2
    LDA proj_x_hi + 3
    SBC proj_x_hi + 2
    BMI @no_f0
    BPL @face0_vis
@f0_8bit:
    LDA proj_x + 2
    CMP proj_x + 3
    BCS @no_f0
@face0_vis:
    LDA face_vis
    ORA #$01
    STA face_vis
@no_f0:

    ; Face 1 (-Z back): visible if proj_x[v1] > proj_x[v0]
    LDA proj_z + 1
    BEQ @face1_vis
    LDA proj_z + 0
    BEQ @face1_vis
    LDA proj_x_hi + 1
    ORA proj_x_hi + 0
    BEQ @f1_8bit
    SEC
    LDA proj_x + 1
    SBC proj_x + 0
    LDA proj_x_hi + 1
    SBC proj_x_hi + 0
    BMI @no_f1
    BPL @face1_vis
@f1_8bit:
    LDA proj_x + 0
    CMP proj_x + 1
    BCS @no_f1
@face1_vis:
    LDA face_vis
    ORA #$02
    STA face_vis
@no_f1:

    ; Face 2 (+X right): visible if proj_x[v2] > proj_x[v1]
    LDA proj_z + 2
    BEQ @face2_vis
    LDA proj_z + 1
    BEQ @face2_vis
    LDA proj_x_hi + 2
    ORA proj_x_hi + 1
    BEQ @f2_8bit
    SEC
    LDA proj_x + 2
    SBC proj_x + 1
    LDA proj_x_hi + 2
    SBC proj_x_hi + 1
    BMI @no_f2
    BPL @face2_vis
@f2_8bit:
    LDA proj_x + 1
    CMP proj_x + 2
    BCS @no_f2
@face2_vis:
    LDA face_vis
    ORA #$04
    STA face_vis
@no_f2:

    ; Face 3 (-X left): visible if proj_x[v0] > proj_x[v3]
    LDA proj_z + 0
    BEQ @face3_vis
    LDA proj_z + 3
    BEQ @face3_vis
    LDA proj_x_hi + 0
    ORA proj_x_hi + 3
    BEQ @f3_8bit
    SEC
    LDA proj_x + 0
    SBC proj_x + 3
    LDA proj_x_hi + 0
    SBC proj_x_hi + 3
    BMI @no_f3
    BPL @face3_vis
@f3_8bit:
    LDA proj_x + 3
    CMP proj_x + 0
    BCS @no_f3
@face3_vis:
    LDA face_vis
    ORA #$08
    STA face_vis
@no_f3:

    ; --- Emit visible edges ---
    LDX #0
@cube_edge_loop:
    CPX #12
    BCS @cube_done

    ; Check face visibility
    LDA cube_edge_faces,X
    AND face_vis
    BEQ @cube_skip

    ; Get vertex indices
    PHX
    LDA cube_edge_v0,X
    TAY
    LDA cube_edge_v1,X
    TAX

    ; Both vertices must be valid
    LDA proj_z,Y
    BEQ @cube_pop
    LDA proj_z,X
    BEQ @cube_pop

    ; Emit line
    JSR emit_edge

@cube_pop:
    PLX
@cube_skip:
    INX
    BRA @cube_edge_loop
@cube_done:
    RTS

; Cube edge tables
cube_edge_v0:
    .byte 0, 1, 2, 3,  4, 5, 6, 7,  0, 1, 2, 3
cube_edge_v1:
    .byte 1, 2, 3, 0,  5, 6, 7, 4,  4, 5, 6, 7
cube_edge_faces:
    ; Bottom(face5=$20): edges 0-3. Top(face4=$10): edges 4-7. Verticals: edges 8-11
    ; face0=front(+Z)=$01, face1=back(-Z)=$02, face2=right(+X)=$04,
    ; face3=left(-X)=$08, face4=top=$10, face5=bottom=$20
    .byte $22,$24,$21,$28, $12,$14,$11,$18, $0A,$06,$05,$09

; =====================================================================
; Process pyramid
; temp0/temp1 = center view X/Z, temp3 = half-size, obj_height = H
; =====================================================================

process_pyramid:
    LDY player_angle

    ; Compute rotated corner offsets (same as cube)
    LDA temp3
    STA math_a
    LDA cos_table,Y
    STA math_b
    JSR smul8x8         ; A = math_res_hi
    ASL math_res_lo
    ROL A
    STA rot_hx
    LDA math_res_lo
    STA rot_hx_frac

    LDA temp3
    STA math_a
    LDA sin_table,Y
    STA math_b
    JSR smul8x8         ; A = math_res_hi
    ASL math_res_lo
    ROL A
    STA rot_kx
    LDA math_res_lo
    STA rot_kx_frac
    ; 8.8 negation: rot_hz:rot_hz_frac = -rot_kx:rot_kx_frac
    LDA #0
    SEC
    SBC rot_kx_frac
    STA rot_hz_frac
    LDA #0
    SBC rot_kx
    STA rot_hz

    ; Project 4 base corners (ground level only, stored at indices 0-3)
    ; Project apex at index 4

    ; Corner 0 (-h, -h)
    SEC
    LDA center_vx_frac
    SBC rot_hx_frac
    STA vx_frac
    LDA temp0
    SBC rot_hx
    TAY
    LDA vx_frac
    SEC
    SBC rot_kx_frac
    STA vx_frac
    TYA
    SBC rot_kx
    STA vx_temp
    ; Fractional VZ
    LDA center_vz_frac
    SEC
    SBC rot_hz_frac
    STA temp2
    LDA temp1
    SBC rot_hz
    TAY
    LDA temp2
    SEC
    SBC rot_hx_frac
    STA vz_frac
    TYA
    SBC rot_hx
    STA vz_temp
    LDX #0
    JSR project_base_only

    ; Corner 1 (+h, -h)
    CLC
    LDA center_vx_frac
    ADC rot_hx_frac
    STA vx_frac
    LDA temp0
    ADC rot_hx
    TAY
    LDA vx_frac
    SEC
    SBC rot_kx_frac
    STA vx_frac
    TYA
    SBC rot_kx
    STA vx_temp
    ; Fractional VZ
    LDA center_vz_frac
    CLC
    ADC rot_hz_frac
    STA temp2
    LDA temp1
    ADC rot_hz
    TAY
    LDA temp2
    SEC
    SBC rot_hx_frac
    STA vz_frac
    TYA
    SBC rot_hx
    STA vz_temp
    LDX #1
    JSR project_base_only

    ; Corner 2 (+h, +h)
    CLC
    LDA center_vx_frac
    ADC rot_hx_frac
    STA vx_frac
    LDA temp0
    ADC rot_hx
    TAY
    LDA vx_frac
    CLC
    ADC rot_kx_frac
    STA vx_frac
    TYA
    ADC rot_kx
    STA vx_temp
    ; Fractional VZ
    LDA center_vz_frac
    CLC
    ADC rot_hz_frac
    STA temp2
    LDA temp1
    ADC rot_hz
    TAY
    LDA temp2
    CLC
    ADC rot_hx_frac
    STA vz_frac
    TYA
    ADC rot_hx
    STA vz_temp
    LDX #2
    JSR project_base_only

    ; Corner 3 (-h, +h)
    SEC
    LDA center_vx_frac
    SBC rot_hx_frac
    STA vx_frac
    LDA temp0
    SBC rot_hx
    TAY
    LDA vx_frac
    CLC
    ADC rot_kx_frac
    STA vx_frac
    TYA
    ADC rot_kx
    STA vx_temp
    ; Fractional VZ
    LDA center_vz_frac
    SEC
    SBC rot_hz_frac
    STA temp2
    LDA temp1
    SBC rot_hz
    TAY
    LDA temp2
    CLC
    ADC rot_hx_frac
    STA vz_frac
    TYA
    ADC rot_hx
    STA vz_temp
    LDX #3
    JSR project_base_only

    ; Halve rotation offsets for frustum top (half-size top square)
    LDA rot_hx
    CMP #$80
    ROR A
    STA rot_hx
    ROR rot_hx_frac

    LDA rot_kx
    CMP #$80
    ROR A
    STA rot_kx
    ROR rot_kx_frac

    LDA rot_hz
    CMP #$80
    ROR A
    STA rot_hz
    ROR rot_hz_frac

    ; Top corner 4 (-h/2, -h/2)
    SEC
    LDA center_vx_frac
    SBC rot_hx_frac
    STA vx_frac
    LDA temp0
    SBC rot_hx
    TAY
    LDA vx_frac
    SEC
    SBC rot_kx_frac
    STA vx_frac
    TYA
    SBC rot_kx
    STA vx_temp
    LDA center_vz_frac
    SEC
    SBC rot_hz_frac
    STA temp2
    LDA temp1
    SBC rot_hz
    TAY
    LDA temp2
    SEC
    SBC rot_hx_frac
    STA vz_frac
    TYA
    SBC rot_hx
    STA vz_temp
    LDX #4
    JSR project_apex

    ; Top corner 5 (+h/2, -h/2)
    CLC
    LDA center_vx_frac
    ADC rot_hx_frac
    STA vx_frac
    LDA temp0
    ADC rot_hx
    TAY
    LDA vx_frac
    SEC
    SBC rot_kx_frac
    STA vx_frac
    TYA
    SBC rot_kx
    STA vx_temp
    LDA center_vz_frac
    CLC
    ADC rot_hz_frac
    STA temp2
    LDA temp1
    ADC rot_hz
    TAY
    LDA temp2
    SEC
    SBC rot_hx_frac
    STA vz_frac
    TYA
    SBC rot_hx
    STA vz_temp
    LDX #5
    JSR project_apex

    ; Top corner 6 (+h/2, +h/2)
    CLC
    LDA center_vx_frac
    ADC rot_hx_frac
    STA vx_frac
    LDA temp0
    ADC rot_hx
    TAY
    LDA vx_frac
    CLC
    ADC rot_kx_frac
    STA vx_frac
    TYA
    ADC rot_kx
    STA vx_temp
    LDA center_vz_frac
    CLC
    ADC rot_hz_frac
    STA temp2
    LDA temp1
    ADC rot_hz
    TAY
    LDA temp2
    CLC
    ADC rot_hx_frac
    STA vz_frac
    TYA
    ADC rot_hx
    STA vz_temp
    LDX #6
    JSR project_apex

    ; Top corner 7 (-h/2, +h/2)
    SEC
    LDA center_vx_frac
    SBC rot_hx_frac
    STA vx_frac
    LDA temp0
    SBC rot_hx
    TAY
    LDA vx_frac
    CLC
    ADC rot_kx_frac
    STA vx_frac
    TYA
    ADC rot_kx
    STA vx_temp
    LDA center_vz_frac
    SEC
    SBC rot_hz_frac
    STA temp2
    LDA temp1
    SBC rot_hz
    TAY
    LDA temp2
    CLC
    ADC rot_hx_frac
    STA vz_frac
    TYA
    ADC rot_hx
    STA vz_temp
    LDX #7
    JSR project_apex

    ; Top face visibility (same logic as cube)
    LDA #CAMERA_Y
    CMP obj_height
    BCC @no_top
    LDA face_vis
    ORA #$10
    STA face_vis
@no_top:

    ; --- Screen-space face culling (8-bit quantized, strict >) ---
    ; Face 0 (+Z front): visible if proj_x[v3] > proj_x[v2]
    LDA proj_z + 3
    BEQ @face0_vis
    LDA proj_z + 2
    BEQ @face0_vis
    LDA proj_x_hi + 3
    ORA proj_x_hi + 2
    BEQ @f0_8bit
    SEC
    LDA proj_x + 3
    SBC proj_x + 2
    LDA proj_x_hi + 3
    SBC proj_x_hi + 2
    BMI @no_f0
    BPL @face0_vis
@f0_8bit:
    LDA proj_x + 2
    CMP proj_x + 3
    BCS @no_f0
@face0_vis:
    LDA face_vis
    ORA #$01
    STA face_vis
@no_f0:

    ; Face 1 (-Z back): visible if proj_x[v1] > proj_x[v0]
    LDA proj_z + 1
    BEQ @face1_vis
    LDA proj_z + 0
    BEQ @face1_vis
    LDA proj_x_hi + 1
    ORA proj_x_hi + 0
    BEQ @f1_8bit
    SEC
    LDA proj_x + 1
    SBC proj_x + 0
    LDA proj_x_hi + 1
    SBC proj_x_hi + 0
    BMI @no_f1
    BPL @face1_vis
@f1_8bit:
    LDA proj_x + 0
    CMP proj_x + 1
    BCS @no_f1
@face1_vis:
    LDA face_vis
    ORA #$02
    STA face_vis
@no_f1:

    ; Face 2 (+X right): visible if proj_x[v2] > proj_x[v1]
    LDA proj_z + 2
    BEQ @face2_vis
    LDA proj_z + 1
    BEQ @face2_vis
    LDA proj_x_hi + 2
    ORA proj_x_hi + 1
    BEQ @f2_8bit
    SEC
    LDA proj_x + 2
    SBC proj_x + 1
    LDA proj_x_hi + 2
    SBC proj_x_hi + 1
    BMI @no_f2
    BPL @face2_vis
@f2_8bit:
    LDA proj_x + 1
    CMP proj_x + 2
    BCS @no_f2
@face2_vis:
    LDA face_vis
    ORA #$04
    STA face_vis
@no_f2:

    ; Face 3 (-X left): visible if proj_x[v0] > proj_x[v3]
    LDA proj_z + 0
    BEQ @face3_vis
    LDA proj_z + 3
    BEQ @face3_vis
    LDA proj_x_hi + 0
    ORA proj_x_hi + 3
    BEQ @f3_8bit
    SEC
    LDA proj_x + 0
    SBC proj_x + 3
    LDA proj_x_hi + 0
    SBC proj_x_hi + 3
    BMI @no_f3
    BPL @face3_vis
@f3_8bit:
    LDA proj_x + 3
    CMP proj_x + 0
    BCS @no_f3
@face3_vis:
    LDA face_vis
    ORA #$08
    STA face_vis
@no_f3:

    ; Emit visible edges (with face culling)
    LDX #0
@pyr_edge_loop:
    CPX #12
    BCS @pyr_done

    ; Check face visibility
    LDA pyr_edge_faces,X
    AND face_vis
    BEQ @pyr_skip

    PHX
    LDA pyr_edge_v0,X
    TAY
    LDA pyr_edge_v1,X
    TAX

    LDA proj_z,Y
    BEQ @pyr_pop
    LDA proj_z,X
    BEQ @pyr_pop

    JSR emit_edge

@pyr_pop:
    PLX
@pyr_skip:
    INX
    BRA @pyr_edge_loop
@pyr_done:
    RTS

pyr_edge_v0:
    .byte 0, 1, 2, 3,  4, 5, 6, 7,  0, 1, 2, 3
pyr_edge_v1:
    .byte 1, 2, 3, 0,  5, 6, 7, 4,  4, 5, 6, 7
pyr_edge_faces:
    .byte $22,$24,$21,$28, $12,$14,$11,$18, $0A,$06,$05,$09

; =====================================================================
; Vertex projection routines
; =====================================================================

; Project a bottom/top vertex pair at the same XZ corner
; Input: vx_temp (signed view X), vz_temp (signed view Z)
;        X = base vertex index, Y = top vertex index
;        obj_height = H
; Uses base_y_temp as scratch
project_corner:
    ; Save vertex indices
    STX pc_base_idx
    STY pc_top_idx

    ; Validity check
    LDA vz_temp
    BMI @pc_inv_jmp
    CMP #128
    BCS @pc_inv_jmp          ; far clip
    CMP #1
    BCS @pc_z_ok
@pc_inv_jmp:
    JMP @pc_invalid
@pc_z_ok:

    ; Mark both vertices valid
    LDX pc_base_idx
    STA proj_z,X
    LDX pc_top_idx
    STA proj_z,X

    ; Extended-range recip lookup (sets recip_val, recip_lo_val, recip_shift)
    JSR recip_lookup

    ; --- Project screen X (with fractional correction) ---
    ; Main displacement: vx * recip_hi
    LDA vx_temp
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    JSR apply_recip_shift
    ; Save main displacement
    LDA math_res_lo
    STA temp2            ; main_lo
    LDA math_res_hi
    PHA                  ; main_hi on stack

    ; Fractional correction: (vx * recip_lo) >> 7 >> recip_shift
    LDA vx_temp
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8          ; A = math_res_hi (signed correction)
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift

    ; Add correction to main displacement
    LDA math_res_hi
    TAX                  ; save correction for sign extension
    BPL @pc_fx_pos
    LDA #$FF             ; negative sign extension
    BRA @pc_fx_add
@pc_fx_pos:
    LDA #0
@pc_fx_add:
    STA math_res_hi      ; sign extension byte
    TXA                  ; correction
    CLC
    ADC temp2            ; main_lo + correction
    STA math_res_lo
    PLA                  ; main_hi
    ADC math_res_hi      ; + sign_ext + carry
    STA math_res_hi

    ; --- vx_frac correction: ((vx_frac >> 1) * recip_val) >> 7 ---
    ; Save displacement
    LDA math_res_lo
    STA temp2
    LDA math_res_hi
    PHA

    ; LSR ensures 0..127 range → smul8x8 treats as unsigned
    LDA vx_frac
    LSR A
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8          ; A = math_res_hi (correction)
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift

    ; Add to displacement (always positive)
    CLC
    LDA temp2
    ADC math_res_hi
    STA math_res_lo
    PLA
    ADC #0
    STA math_res_hi

    ; 16-bit: screen_x = 128 + displacement → store in proj_x_hi:proj_x
    CLC
    LDA #128
    ADC math_res_lo
    PHA                 ; save lo byte
    LDA #0
    ADC math_res_hi     ; hi byte (0 = on-screen)
    ; Store 16-bit X for both base and top
    LDX pc_base_idx
    STA proj_x_hi,X
    LDX pc_top_idx
    STA proj_x_hi,X
    PLA
    LDX pc_base_idx
    STA proj_x,X
    LDX pc_top_idx
    STA proj_x,X

    ; --- Project base screen Y (16-bit unclamped) ---
    ; base_y = HORIZON_Y + (3 * recip_val) >> recip_shift + (CAMERA_Y * recip_lo) >> 7
    ; Result stored as 16-bit in temp3:base_y_temp
    LDA recip_val
    ASL A
    STA temp2               ; 2*recip lo
    LDA #0
    ROL A
    STA temp3               ; 2*recip hi (0 or 1)
    LDA temp2
    CLC
    ADC recip_val
    STA temp2
    LDA temp3
    ADC #0
    STA temp3               ; temp3:temp2 = 3*recip (9-bit)
    ; Apply recip_shift (16-bit)
    LDX recip_shift
    BEQ @pc_no_base_shift
@pc_base_shift:
    LSR temp3
    ROR temp2
    DEX
    BNE @pc_base_shift
@pc_no_base_shift:
    ; + HORIZON_Y → 16-bit base_y
    LDA temp2
    CLC
    ADC #HORIZON_Y
    STA base_y_temp
    LDA temp3
    ADC #0
    STA temp3
    ; recip_lo smoothing for Y
    LDA #CAMERA_Y
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift
    ; Sign-extend math_res_hi and add to 16-bit base_y
    LDA math_res_hi
    BPL @pc_by_corr_pos
    ; Negative correction: sign-extend with $FF
    CLC
    ADC base_y_temp
    STA base_y_temp
    LDA temp3
    ADC #$FF
    STA temp3
    BRA @pc_store_base
@pc_by_corr_pos:
    CLC
    ADC base_y_temp
    STA base_y_temp
    LDA temp3
    ADC #0
    STA temp3

@pc_store_base:
    LDX pc_base_idx
    LDA base_y_temp
    STA proj_y,X
    LDA temp3
    STA proj_y_hi,X

    ; --- Project top screen Y (16-bit unclamped) ---
    ; height = (H * recip_val + (H * recip_lo) >> 7) >> recip_shift
    ; top_y = base_y - height (all 16-bit, no clamping)
    LDA obj_height
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    JSR apply_recip_shift
    ; Save 16-bit main height
    LDA math_res_lo
    STA temp2               ; height_lo
    LDA math_res_hi
    PHA                     ; height_hi on stack

    ; Fractional correction: (H * recip_lo) >> 7 >> recip_shift
    LDA obj_height
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift

    ; Add signed correction to 16-bit height
    LDA math_res_hi
    BPL @pc_hc_pos
    ; Negative correction (sign extend $FF)
    CLC
    ADC temp2
    STA temp2
    PLA                     ; height_hi (carry preserved through PLA)
    ADC #$FF
    BRA @pc_sub_height
@pc_hc_pos:
    CLC
    ADC temp2
    STA temp2
    PLA
    ADC #0
@pc_sub_height:
    ; A = height_hi, temp2 = height_lo
    ; top_y = base_y - height (16-bit subtraction)
    STA math_res_hi         ; save height_hi
    LDA base_y_temp
    SEC
    SBC temp2
    PHA                     ; top_y lo
    LDA temp3               ; base_y hi
    SBC math_res_hi
    LDX pc_top_idx
    STA proj_y_hi,X
    PLA
    STA proj_y,X
    RTS

@pc_invalid:
    LDX pc_base_idx
    LDA #0
    STA proj_z,X
    STA proj_y_hi,X
    LDX pc_top_idx
    STA proj_z,X
    STA proj_y_hi,X
    RTS

; Scratch for project_corner
pc_base_idx:    .byte 0
pc_top_idx:     .byte 0

; Project a single ground-level vertex (for pyramid base)
; Input: vx_temp, vz_temp, X = vertex index
project_base_only:
    STX pc_base_idx     ; save vertex index (smul8x8 clobbers X)
    LDA vz_temp
    BMI @pb_inv_jmp
    CMP #128
    BCS @pb_inv_jmp      ; far clip
    CMP #1
    BCS @pb_z_ok
@pb_inv_jmp:
    JMP @pb_invalid
@pb_z_ok:
    STA proj_z,X

    ; Extended-range recip lookup (sets recip_val, recip_lo_val, recip_shift)
    JSR recip_lookup

    ; Project X (with fractional correction)
    LDA vx_temp
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    JSR apply_recip_shift
    LDA math_res_lo
    STA temp2
    LDA math_res_hi
    PHA

    ; Fractional correction
    LDA vx_temp
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift

    LDA math_res_hi
    TAX
    BPL @pb_fx_pos
    LDA #$FF
    BRA @pb_fx_add
@pb_fx_pos:
    LDA #0
@pb_fx_add:
    STA math_res_hi
    TXA
    CLC
    ADC temp2
    STA math_res_lo
    PLA
    ADC math_res_hi
    STA math_res_hi

    ; --- vx_frac correction: ((vx_frac >> 1) * recip_val) >> 7 ---
    LDA math_res_lo
    STA temp2
    LDA math_res_hi
    PHA

    LDA vx_frac
    LSR A
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift

    CLC
    LDA temp2
    ADC math_res_hi
    STA math_res_lo
    PLA
    ADC #0
    STA math_res_hi

    LDX pc_base_idx     ; restore vertex index
    CLC
    LDA #128
    ADC math_res_lo
    STA proj_x,X
    LDA #0
    ADC math_res_hi
    STA proj_x_hi,X

@pb_y:
    ; base_y = HORIZON_Y + (3 * recip) >> recip_shift + (CAMERA_Y * recip_lo) >> 7
    ; 16-bit unclamped
    LDA recip_val
    ASL A
    STA temp2               ; 2*recip lo
    LDA #0
    ROL A
    STA temp3               ; 2*recip hi (0 or 1)
    LDA temp2
    CLC
    ADC recip_val
    STA temp2
    LDA temp3
    ADC #0
    STA temp3               ; temp3:temp2 = 3*recip (9-bit)
    ; Apply recip_shift (16-bit)
    LDX recip_shift
    BEQ @pb_no_base_shift
@pb_base_shift:
    LSR temp3
    ROR temp2
    DEX
    BNE @pb_base_shift
@pb_no_base_shift:
    ; + HORIZON_Y → 16-bit base_y
    LDA temp2
    CLC
    ADC #HORIZON_Y
    STA base_y_temp
    LDA temp3
    ADC #0
    STA temp3
    ; recip_lo smoothing for Y
    LDA #CAMERA_Y
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift
    ; Sign-extend math_res_hi and add to 16-bit base_y
    LDX pc_base_idx
    LDA math_res_hi
    BPL @pb_by_corr_pos
    CLC
    ADC base_y_temp
    STA proj_y,X
    LDA temp3
    ADC #$FF
    STA proj_y_hi,X
    RTS
@pb_by_corr_pos:
    CLC
    ADC base_y_temp
    STA proj_y,X
    LDA temp3
    ADC #0
    STA proj_y_hi,X
    RTS

@pb_invalid:
    LDA #0
    STA proj_z,X
    STA proj_y_hi,X
    RTS

; Project pyramid apex (at center, height H)
; Input: vx_temp, vz_temp, X = vertex index (4)
project_apex:
    STX pc_base_idx     ; save vertex index (smul8x8 clobbers X)
    LDA vz_temp
    BMI @pa_inv_jmp
    CMP #128
    BCS @pa_inv_jmp      ; far clip
    CMP #1
    BCS @pa_z_ok
@pa_inv_jmp:
    JMP @pa_invalid
@pa_z_ok:
    STA proj_z,X

    ; Extended-range recip lookup (sets recip_val, recip_lo_val, recip_shift)
    JSR recip_lookup

    ; Project X (with fractional correction)
    LDA vx_temp
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    JSR apply_recip_shift
    LDA math_res_lo
    STA temp2
    LDA math_res_hi
    PHA

    LDA vx_temp
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift

    LDA math_res_hi
    TAX
    BPL @pa_fx_pos
    LDA #$FF
    BRA @pa_fx_add
@pa_fx_pos:
    LDA #0
@pa_fx_add:
    STA math_res_hi
    TXA
    CLC
    ADC temp2
    STA math_res_lo
    PLA
    ADC math_res_hi
    STA math_res_hi

    ; --- vx_frac correction: ((vx_frac >> 1) * recip_val) >> 7 ---
    LDA math_res_lo
    STA temp2
    LDA math_res_hi
    PHA

    LDA vx_frac
    LSR A
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift

    CLC
    LDA temp2
    ADC math_res_hi
    STA math_res_lo
    PLA
    ADC #0
    STA math_res_hi

    LDX pc_base_idx
    CLC
    LDA #128
    ADC math_res_lo
    STA proj_x,X
    LDA #0
    ADC math_res_hi
    STA proj_x_hi,X

@pa_y:
    ; apex_y = (HORIZON_Y + (3*recip)>>shift + (CAMERA_Y*recip_lo)>>7) - (H*recip + (H*recip_lo)>>7)
    ; All 16-bit unclamped
    ; Compute 16-bit base_y in temp3:base_y_temp
    LDA recip_val
    ASL A
    STA temp2               ; 2*recip lo
    LDA #0
    ROL A
    STA temp3               ; 2*recip hi (0 or 1)
    LDA temp2
    CLC
    ADC recip_val
    STA temp2
    LDA temp3
    ADC #0
    STA temp3               ; temp3:temp2 = 3*recip (9-bit)
    ; Apply recip_shift (16-bit)
    LDX recip_shift
    BEQ @pa_no_base_shift
@pa_base_shift:
    LSR temp3
    ROR temp2
    DEX
    BNE @pa_base_shift
@pa_no_base_shift:
    ; + HORIZON_Y → 16-bit base_y
    LDA temp2
    CLC
    ADC #HORIZON_Y
    STA base_y_temp
    LDA temp3
    ADC #0
    STA temp3
    ; recip_lo smoothing for Y
    LDA #CAMERA_Y
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift
    ; Sign-extend math_res_hi and add to 16-bit base_y
    LDA math_res_hi
    BPL @pa_by_corr_pos
    CLC
    ADC base_y_temp
    STA base_y_temp
    LDA temp3
    ADC #$FF
    STA temp3
    BRA @pa_height
@pa_by_corr_pos:
    CLC
    ADC base_y_temp
    STA base_y_temp
    LDA temp3
    ADC #0
    STA temp3

@pa_height:
    ; Compute 16-bit height: H * recip_val + (H * recip_lo) >> 7
    LDA obj_height
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    JSR apply_recip_shift
    ; Save 16-bit main height
    LDA math_res_lo
    STA temp2               ; height_lo
    LDA math_res_hi
    PHA                     ; height_hi on stack

    ; Fractional correction: (H * recip_lo) >> 7 >> recip_shift
    LDA obj_height
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    ROL math_res_hi
    JSR apply_recip_shift

    ; Add signed correction to 16-bit height
    LDA math_res_hi
    BPL @pa_hc_pos
    ; Negative correction (sign extend $FF)
    CLC
    ADC temp2
    STA temp2
    PLA                     ; height_hi (carry preserved through PLA)
    ADC #$FF
    BRA @pa_sub_height
@pa_hc_pos:
    CLC
    ADC temp2
    STA temp2
    PLA
    ADC #0
@pa_sub_height:
    ; A = height_hi, temp2 = height_lo
    ; apex_y = base_y - height (16-bit subtraction)
    STA math_res_hi         ; save height_hi
    LDA base_y_temp
    SEC
    SBC temp2
    PHA                     ; apex_y lo
    LDA temp3               ; base_y hi
    SBC math_res_hi
    LDX pc_base_idx
    STA proj_y_hi,X
    PLA
    STA proj_y,X
    RTS

@pa_invalid:
    LDA #0
    STA proj_z,X
    STA proj_y_hi,X
    RTS

; =====================================================================
; Emit edge — add projected edge to new_lines
; Y = vertex 0 index, X = vertex 1 index
; Uses temp2, recip_val as scratch (safe: not needed during emit)
; =====================================================================

emit_edge:
    ; Y = v0 index, X = v1 index
    LDA num_new_lines
    CMP #64
    BCC @ee_not_full
    RTS                     ; line buffer full → early out
@ee_not_full:

    ; Load full coordinates into clipper workspace
    LDA proj_x,Y
    STA clip_x0_lo
    LDA proj_x_hi,Y
    STA clip_x0_hi
    LDA proj_y,Y
    STA clip_y0
    LDA proj_y_hi,Y
    STA clip_y0_hi

    LDA proj_x,X
    STA clip_x1_lo
    LDA proj_x_hi,X
    STA clip_x1_hi
    LDA proj_y,X
    STA clip_y1
    LDA proj_y_hi,X
    STA clip_y1_hi

    ; Quick check: both X on-screen? (both hi bytes = 0)
    LDA clip_x0_hi
    ORA clip_x1_hi
    BEQ @ee_store           ; both on-screen → store (Y clamped at store)

    ; Trivial reject: both off same side?
    LDA clip_x0_hi
    BEQ @ee_clip            ; x0 on-screen → need clipping, not reject
    LDA clip_x1_hi
    BEQ @ee_clip            ; x1 on-screen → need clipping
    ; Both off-screen — same side?
    EOR clip_x0_hi          ; XOR: same sign → bit 7 clear
    BMI @ee_clip            ; different signs → spans screen, need clip
    RTS                     ; same side → trivial reject

@ee_clip:
    ; Clip endpoint 0 if off-screen
    LDA clip_x0_hi
    BEQ @ee_e0_ok
    BMI @ee_e0_left
    LDA #255                ; right → clip to x=255
    JSR clip_endpoint_0
    BRA @ee_e0_ok
@ee_e0_left:
    LDA #0                  ; left → clip to x=0
    JSR clip_endpoint_0
@ee_e0_ok:

    ; Clip endpoint 1 if off-screen
    LDA clip_x1_hi
    BEQ @ee_store
    BMI @ee_e1_left
    LDA #255
    JSR clip_endpoint_1
    BRA @ee_store
@ee_e1_left:
    LDA #0
    JSR clip_endpoint_1

@ee_store:
    ; --- Y trivial reject + Y-clipping ---
    LDA clip_y0_hi
    ORA clip_y1_hi
    BEQ @ee_y_done          ; both Y on-screen → skip

    ; At least one endpoint has Y off-screen
    LDA clip_y0_hi
    BEQ @ee_y_clip          ; y0 on-screen → clip y1 only
    LDA clip_y1_hi
    BEQ @ee_y_clip          ; y1 on-screen → clip y0 only
    ; Both off-screen — same side?
    EOR clip_y0_hi          ; XOR: same sign → bit 7 clear
    BPL ee_y_reject         ; same sign → reject

@ee_y_clip:
    ; Clip y0 if off-screen
    LDA clip_y0_hi
    BEQ @ee_y0_ok
    BMI @ee_y0_above
    LDA #255                ; y0 > 255 → clip to bottom
    JSR y_clip_endpoint_0
    BRA @ee_y0_ok
@ee_y0_above:
    LDA #0                  ; y0 < 0 → clip to top
    JSR y_clip_endpoint_0
@ee_y0_ok:
    ; Clip y1 if off-screen
    LDA clip_y1_hi
    BEQ @ee_y_done
    BMI @ee_y1_above
    LDA #255
    JSR y_clip_endpoint_1
    BRA @ee_y_done
@ee_y1_above:
    LDA #0
    JSR y_clip_endpoint_1

@ee_y_done:
    ; Store the (clipped) line into current buffer (addresses patched by build_scene)
    LDA num_new_lines
    ASL A
    ASL A               ; * 4
    TAX
    LDA clip_x0_lo
ee_store_x0:
    STA lines_0,X       ; SMC: hi byte patched per buffer
    LDA clip_y0
ee_store_y0:
    STA lines_0+1,X     ; SMC
    LDA clip_x1_lo
ee_store_x1:
    STA lines_0+2,X     ; SMC
    LDA clip_y1
ee_store_y1:
    STA lines_0+3,X     ; SMC
    INC num_new_lines
    RTS

ee_y_reject:
    RTS

; ── Clip endpoint 0 to boundary ──────────────────────────────────────
; A = boundary (0 or 255)
; Updates clip_x0_lo, clip_x0_hi, clip_y0
; Uses endpoint 1 for interpolation

clip_endpoint_0:
    STA clip_boundary       ; save boundary ($91, avoids temp2 conflict)

    ; numerator = |boundary - x0| (16-bit)
    SEC
    SBC clip_x0_lo
    STA clip_num_lo
    LDA #0
    SBC clip_x0_hi
    STA clip_num_hi
    BPL @ce0_nabs
    LDA #0
    SEC
    SBC clip_num_lo
    STA clip_num_lo
    LDA #0
    SBC clip_num_hi
    STA clip_num_hi
@ce0_nabs:

    ; denominator = |x1 - x0| (16-bit)
    LDA clip_x1_lo
    SEC
    SBC clip_x0_lo
    STA clip_dx_lo
    LDA clip_x1_hi
    SBC clip_x0_hi
    STA clip_dx_hi
    BPL @ce0_dabs
    LDA #0
    SEC
    SBC clip_dx_lo
    STA clip_dx_lo
    LDA #0
    SBC clip_dx_hi
    STA clip_dx_hi
@ce0_dabs:

    ; ratio = numerator / denominator as 0.8 fraction
    JSR div_frac8           ; → clip_ratio

    ; --- 16-bit Y interpolation ---
    ; delta = y1 - y0 (16-bit signed)
    LDA clip_y1
    SEC
    SBC clip_y0
    STA clip_dx_lo          ; reuse (X division done)
    LDA clip_y1_hi
    SBC clip_y0_hi
    STA clip_dx_hi

    ; Absolute value; save sign via PHP (C=1 → subtract from y0)
    BPL @ce0_dy_pos
    ; Negate 16-bit delta
    LDA #0
    SEC
    SBC clip_dx_lo
    STA clip_dx_lo
    LDA #0
    SBC clip_dx_hi
    STA clip_dx_hi
    SEC                     ; C=1: delta was negative → subtract
    BRA @ce0_dy_abs
@ce0_dy_pos:
    CLC                     ; C=0: delta was positive → add
@ce0_dy_abs:
    PHP                     ; save sign on stack

    ; 16×8→16 multiply: |delta| * ratio >> 8
    ; = umul8x8(delta_hi, ratio).lo + umul8x8(delta_lo, ratio).hi
    ; Part A: umul8x8(delta_lo, ratio), save .hi in temp2
    LDA clip_dx_lo
    STA math_a
    LDA clip_ratio
    STA math_b
    JSR umul8x8
    LDA math_res_hi
    STA temp2               ; partial product hi

    ; Part B: umul8x8(delta_hi, ratio)
    LDA clip_dx_hi
    STA math_a
    ; math_b still = clip_ratio (umul8x8 preserves it)
    JSR umul8x8
    ; Combine: product = math_res_hi : (math_res_lo + temp2)
    LDA math_res_lo
    CLC
    ADC temp2
    STA temp2               ; product lo
    LDA math_res_hi
    ADC #0
    STA temp3               ; product hi

    ; Apply sign and add/subtract to clip_y0_hi:clip_y0
    PLP
    BCS @ce0_dy_sub
    ; Add: new_y0 = y0 + product
    LDA clip_y0
    CLC
    ADC temp2
    STA clip_y0
    LDA clip_y0_hi
    ADC temp3
    STA clip_y0_hi
    BRA @ce0_setx
@ce0_dy_sub:
    ; Subtract: new_y0 = y0 - product
    LDA clip_y0
    SEC
    SBC temp2
    STA clip_y0
    LDA clip_y0_hi
    SBC temp3
    STA clip_y0_hi

@ce0_setx:
    ; No Y clamp here — @ee_store handles it for all paths
    LDA clip_boundary
    STA clip_x0_lo
    STZ clip_x0_hi
    RTS

; ── Clip endpoint 1 to boundary ──────────────────────────────────────
; A = boundary (0 or 255)
; Updates clip_x1_lo, clip_x1_hi, clip_y1
; Uses endpoint 0 for interpolation

clip_endpoint_1:
    STA clip_boundary       ; save boundary ($91, avoids temp2 conflict)

    ; numerator = |boundary - x1|
    SEC
    SBC clip_x1_lo
    STA clip_num_lo
    LDA #0
    SBC clip_x1_hi
    STA clip_num_hi
    BPL @ce1_nabs
    LDA #0
    SEC
    SBC clip_num_lo
    STA clip_num_lo
    LDA #0
    SBC clip_num_hi
    STA clip_num_hi
@ce1_nabs:

    ; denominator = |x0 - x1|
    LDA clip_x0_lo
    SEC
    SBC clip_x1_lo
    STA clip_dx_lo
    LDA clip_x0_hi
    SBC clip_x1_hi
    STA clip_dx_hi
    BPL @ce1_dabs
    LDA #0
    SEC
    SBC clip_dx_lo
    STA clip_dx_lo
    LDA #0
    SBC clip_dx_hi
    STA clip_dx_hi
@ce1_dabs:

    JSR div_frac8

    ; --- 16-bit Y interpolation ---
    ; delta = y0 - y1 (16-bit signed)
    LDA clip_y0
    SEC
    SBC clip_y1
    STA clip_dx_lo          ; reuse (X division done)
    LDA clip_y0_hi
    SBC clip_y1_hi
    STA clip_dx_hi

    ; Absolute value; save sign via PHP (C=1 → subtract from y1)
    BPL @ce1_dy_pos
    ; Negate 16-bit delta
    LDA #0
    SEC
    SBC clip_dx_lo
    STA clip_dx_lo
    LDA #0
    SBC clip_dx_hi
    STA clip_dx_hi
    SEC                     ; C=1: delta was negative → subtract
    BRA @ce1_dy_abs
@ce1_dy_pos:
    CLC                     ; C=0: delta was positive → add
@ce1_dy_abs:
    PHP                     ; save sign on stack

    ; 16×8→16 multiply: |delta| * ratio >> 8
    ; Part A: umul8x8(delta_lo, ratio), save .hi in temp2
    LDA clip_dx_lo
    STA math_a
    LDA clip_ratio
    STA math_b
    JSR umul8x8
    LDA math_res_hi
    STA temp2               ; partial product hi

    ; Part B: umul8x8(delta_hi, ratio)
    LDA clip_dx_hi
    STA math_a
    ; math_b still = clip_ratio (umul8x8 preserves it)
    JSR umul8x8
    ; Combine: product = math_res_hi : (math_res_lo + temp2)
    LDA math_res_lo
    CLC
    ADC temp2
    STA temp2               ; product lo
    LDA math_res_hi
    ADC #0
    STA temp3               ; product hi

    ; Apply sign and add/subtract to clip_y1_hi:clip_y1
    PLP
    BCS @ce1_dy_sub
    ; Add: new_y1 = y1 + product
    LDA clip_y1
    CLC
    ADC temp2
    STA clip_y1
    LDA clip_y1_hi
    ADC temp3
    STA clip_y1_hi
    BRA @ce1_setx
@ce1_dy_sub:
    ; Subtract: new_y1 = y1 - product
    LDA clip_y1
    SEC
    SBC temp2
    STA clip_y1
    LDA clip_y1_hi
    SBC temp3
    STA clip_y1_hi

@ce1_setx:
    ; No Y clamp here — @ee_store handles it for all paths
    LDA clip_boundary
    STA clip_x1_lo
    STZ clip_x1_hi
    RTS

; ── Y-clip endpoint 0 to Y boundary ──────────────────────────────────
; A = Y boundary (0 or 255)
; Clips y0 to boundary, computing new x0 by interpolation
; Updates clip_x0_lo, clip_y0, clip_y0_hi
; Reuses clipper ZP workspace (clip_num, clip_dx, clip_ratio)

y_clip_endpoint_0:
    STA clip_boundary

    ; numerator = |boundary - y0| (16-bit)
    SEC
    SBC clip_y0
    STA clip_num_lo
    LDA #0
    SBC clip_y0_hi
    STA clip_num_hi
    BPL @yc0_nabs
    LDA #0
    SEC
    SBC clip_num_lo
    STA clip_num_lo
    LDA #0
    SBC clip_num_hi
    STA clip_num_hi
@yc0_nabs:

    ; denominator = |y1 - y0| (16-bit)
    LDA clip_y1
    SEC
    SBC clip_y0
    STA clip_dx_lo
    LDA clip_y1_hi
    SBC clip_y0_hi
    STA clip_dx_hi
    BPL @yc0_dabs
    LDA #0
    SEC
    SBC clip_dx_lo
    STA clip_dx_lo
    LDA #0
    SBC clip_dx_hi
    STA clip_dx_hi
@yc0_dabs:

    JSR div_frac8           ; clip_ratio = |boundary - y0| * 256 / |y1 - y0|

    ; X interpolation: new_x0 = x0 + ratio * (x1 - x0) / 256
    ; x0, x1 are 8-bit [0,255] after X-clipping
    LDA clip_x1_lo
    SEC
    SBC clip_x0_lo          ; A = x1 - x0 (signed 8-bit)
    BCS @yc0_dx_pos         ; no borrow → positive

    ; Negative dx: negate, multiply, subtract from x0
    EOR #$FF
    CLC
    ADC #1                  ; A = |dx|
    STA math_a
    LDA clip_ratio
    STA math_b
    JSR umul8x8
    LDA clip_x0_lo
    SEC
    SBC math_res_hi
    STA clip_x0_lo
    BRA @yc0_set

@yc0_dx_pos:
    STA math_a
    LDA clip_ratio
    STA math_b
    JSR umul8x8
    LDA clip_x0_lo
    CLC
    ADC math_res_hi
    STA clip_x0_lo

@yc0_set:
    LDA clip_boundary
    STA clip_y0
    STZ clip_y0_hi
    RTS

; ── Y-clip endpoint 1 to Y boundary ──────────────────────────────────
; A = Y boundary (0 or 255)
; Clips y1 to boundary, computing new x1 by interpolation
; Uses UPDATED y0/x0 after y_clip_endpoint_0
; Updates clip_x1_lo, clip_y1, clip_y1_hi

y_clip_endpoint_1:
    STA clip_boundary

    ; numerator = |boundary - y1| (16-bit)
    SEC
    SBC clip_y1
    STA clip_num_lo
    LDA #0
    SBC clip_y1_hi
    STA clip_num_hi
    BPL @yc1_nabs
    LDA #0
    SEC
    SBC clip_num_lo
    STA clip_num_lo
    LDA #0
    SBC clip_num_hi
    STA clip_num_hi
@yc1_nabs:

    ; denominator = |y0 - y1| (16-bit, uses UPDATED y0)
    LDA clip_y0
    SEC
    SBC clip_y1
    STA clip_dx_lo
    LDA clip_y0_hi
    SBC clip_y1_hi
    STA clip_dx_hi
    BPL @yc1_dabs
    LDA #0
    SEC
    SBC clip_dx_lo
    STA clip_dx_lo
    LDA #0
    SBC clip_dx_hi
    STA clip_dx_hi
@yc1_dabs:

    JSR div_frac8

    ; X interpolation: new_x1 = x1 + ratio * (x0 - x1) / 256
    ; Uses UPDATED x0 after y_clip_endpoint_0
    LDA clip_x0_lo
    SEC
    SBC clip_x1_lo          ; A = x0 - x1 (signed 8-bit)
    BCS @yc1_dx_pos

    ; Negative dx: negate, multiply, subtract from x1
    EOR #$FF
    CLC
    ADC #1
    STA math_a
    LDA clip_ratio
    STA math_b
    JSR umul8x8
    LDA clip_x1_lo
    SEC
    SBC math_res_hi
    STA clip_x1_lo
    BRA @yc1_set

@yc1_dx_pos:
    STA math_a
    LDA clip_ratio
    STA math_b
    JSR umul8x8
    LDA clip_x1_lo
    CLC
    ADC math_res_hi
    STA clip_x1_lo

@yc1_set:
    LDA clip_boundary
    STA clip_y1
    STZ clip_y1_hi
    RTS

; ── 16÷16 fractional division ────────────────────────────────────────
; Input:  clip_num_hi:clip_num_lo = numerator (unsigned, < denominator)
;         clip_dx_hi:clip_dx_lo = denominator (unsigned, > 0)
; Output: clip_ratio = floor(numerator * 256 / denominator), 0-255
; Clobbers: A, Y, temp3

div_frac8:
    STZ temp3               ; overflow bit for 17-bit remainder
    STZ clip_ratio
    LDY #8
@dfl:
    ; R <<= 1 (17-bit shift through temp3:clip_num_hi:clip_num_lo)
    ASL clip_num_lo
    ROL clip_num_hi
    ROL temp3

    ; Compare R with D: if temp3 > 0, R >= D
    LDA temp3
    BNE @df_sub
    LDA clip_num_hi
    CMP clip_dx_hi
    BCC @df_no
    BNE @df_sub
    LDA clip_num_lo
    CMP clip_dx_lo
    BCC @df_no
@df_sub:
    ; R -= D
    LDA clip_num_lo
    SEC
    SBC clip_dx_lo
    STA clip_num_lo
    LDA clip_num_hi
    SBC clip_dx_hi
    STA clip_num_hi
    STZ temp3               ; overflow cleared
    SEC                     ; quotient bit = 1
    BRA @df_next
@df_no:
    CLC                     ; quotient bit = 0
@df_next:
    ROL clip_ratio
    DEY
    BNE @dfl
    RTS

; ── Unsigned 8x8 → 16-bit multiply ──────────────────────────────────
; Input:  math_a, math_b (unsigned)
; Output: math_res_hi:math_res_lo
; Clobbers: A, X, math_a

umul8x8:
    LDA #0
    STA math_res_hi
    LDX #8
@uml:
    LSR math_a
    BCC @um_no
    CLC
    ADC math_b
@um_no:
    ROR A
    ROR math_res_hi
    DEX
    BNE @uml
    LDX math_res_hi
    STX math_res_lo
    STA math_res_hi
    RTS

; =====================================================================
; Signed 8x8 → 16-bit multiply
; Input:  math_a (signed), math_b (signed)
; Output: math_res_hi:math_res_lo (signed 16-bit)
; =====================================================================

smul8x8:
    PHY                 ; save Y (callers depend on preservation)

    ; Unsigned quarter-square multiply with signed correction
    ; Avoids abs/negate of inputs and conditional 16-bit negate of result

    ; Compute |a - b| first (independent of sum overflow)
    LDA math_a
    SEC
    SBC math_b
    BCS @diff_pos
    EOR #$FF
    INC A               ; 65C02: negate for |diff|
@diff_pos:
    TAY                  ; Y = |a - b|

    ; Compute sum (unsigned)
    LDA math_a
    CLC
    ADC math_b           ; A = (a + b) & $FF
    TAX                  ; X = sum low byte
    BCS @sum_hi          ; sum >= 256, use sqr2 tables

    ; Sum < 256: result = sqr1[sum] - sqr1[|diff|]
    SEC
    LDA sqr_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr_hi,X
    SBC sqr_hi,Y         ; A = unsigned result hi
    BRA @sign_corr

@sum_hi:
    ; Sum >= 256: result = sqr2[sum-256] - sqr1[|diff|]
    SEC
    LDA sqr2_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr2_hi,X
    SBC sqr_hi,Y         ; A = unsigned result hi

@sign_corr:
    ; Signed correction: subtract 256*b if a<0, subtract 256*a if b<0
    ; Carry hi in A throughout, use X for sign tests
    LDX math_a
    BPL @a_pos
    SEC
    SBC math_b
@a_pos:
    LDX math_b
    BPL @done
    SEC
    SBC math_a
@done:
    STA math_res_hi      ; store final result; A also holds it on exit
    PLY                  ; restore Y
    RTS

; recip_lookup: Extended-range reciprocal table lookup
; Input: A = vz_temp (1..127), vz_frac in ZP
; Output: recip_val, recip_lo_val, recip_shift set
; Clobbers: A, X (Y preserved)
recip_lookup:
    CMP #66
    BCS @range2
    CMP #33
    BCS @range1

    ; Range 0: z in [1, 33), direct lookup with full fractional precision
    SEC
    SBC #1
    ASL A
    ASL A
    ASL A
    STA temp2
    LDA vz_frac
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    ORA temp2
    TAX
    LDA recip_table,X
    STA recip_val
    LDA recip_lo_table,X
    STA recip_lo_val
    STZ recip_shift
    RTS

@range1:
    ; z in [33, 66), halve z with full K=8 fractional precision, shift=1
    LSR A               ; A = vz_temp/2, carry = vz_temp bit 0
    PHA                 ; save halved integer part
    ; Sub-index = top 3 bits of halved fractional: (carry << 2) | (vz_frac >> 6)
    LDA vz_frac
    ROR A               ; carry (vz_temp[0]) -> bit7, vz_frac[7:1] -> bits 6..0
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A               ; A = (vz_temp[0] << 2) | (vz_frac >> 6) = 0..7
    STA temp2
    PLA
    SEC
    SBC #1
    ASL A
    ASL A
    ASL A
    ORA temp2
    TAX
    LDA recip_table,X
    STA recip_val
    LDA recip_lo_table,X
    STA recip_lo_val
    LDA #1
    STA recip_shift
    RTS

@range2:
    ; z in [66, 128), quarter z with full K=8 fractional precision, shift=2
    ; sub_idx = (vz_temp & 3) * 2 + (vz_frac >> 7) = 0..7
    PHA                 ; save vz_temp
    AND #3              ; A = vz_temp & 3
    ASL A               ; A = (vz_temp & 3) * 2
    STA temp2
    LDA vz_frac
    ASL A               ; carry = vz_frac bit 7
    LDA temp2
    ADC #0              ; A = sub_idx (0..7)
    STA temp2
    PLA                 ; restore vz_temp
    LSR A
    LSR A               ; A = vz_temp / 4
    SEC
    SBC #1
    ASL A
    ASL A
    ASL A
    ORA temp2
    TAX
    LDA recip_table,X
    STA recip_val
    LDA recip_lo_table,X
    STA recip_lo_val
    LDA #2
    STA recip_shift
    RTS

; apply_recip_shift: Arithmetic right-shift math_res by recip_shift
; Clobbers: A, X
apply_recip_shift:
    LDX recip_shift
    BEQ @done
@loop:
    LDA math_res_hi
    CMP #$80            ; carry = sign bit
    ROR math_res_hi
    ROR math_res_lo
    DEX
    BNE @loop
@done:
    RTS

; =====================================================================
; Object table
; Format: world_x, world_z, type(0=cube,1=pyr), half_size, height, 0, 0, 0
; Player starts at (128, 64). Objects ahead (higher Z values).
; =====================================================================

NUM_OBJECTS = 6

obj_table:
    ; Object 0: cube directly ahead
    .byte 128, 90, 0, 4, 16, 0, 0, 0
    ; Object 1: cube ahead-right
    .byte 145, 100, 0, 3, 12, 0, 0, 0
    ; Object 2: pyramid ahead-left
    .byte 110, 95, 1, 3, 12, 0, 0, 0
    ; Object 3: cube far ahead
    .byte 130, 130, 0, 5, 14, 0, 0, 0
    ; Object 4: pyramid far right
    .byte 160, 110, 1, 4, 14, 0, 0, 0
    ; Object 5: cube near-left
    .byte 115, 80, 0, 3, 10, 0, 0, 0

; =====================================================================
; Lookup tables
; =====================================================================

.include "tables.inc"

; =====================================================================
; Line rasterizer (Bresenham)
; =====================================================================

mask_init_table:
    .byte $80, $40, $20, $10, $08, $04, $02, $01

.ifndef UNROLL_SHALLOW
fwd_branch_table:
    .byte opBBR6, opBBR5, opBBR4, opBBR3, opBBR2, opBBR1, opBBR0
rev_branch_table:
    .byte opBCC, opBBR7, opBBR6, opBBR5, opBBR4, opBBR3, opBBR2, opBBR1
.endif

draw_line:
    LDA x1
    CMP x0
    BCS @no_swap
    LDX x0
    STA x0
    STX x1
    LDA y0
    LDX y1
    STA y1
    STX y0
@no_swap:
    LDA y0
    SEC
    SBC y1
    BCS @abs_dy
    EOR #$FF
    INC A
@abs_dy:
    TAY
    LDA x1
    SEC
    SBC x0
    BEQ @go_vertical
    STY delta_minor
    CMP delta_minor
    BCS shallow_setup
    JMP steep_setup
@go_vertical:
    JMP vertical_setup

.ifdef UNROLL_SHALLOW

; === SHALLOW PATH (unrolled, 8 pixels/byte) ===

smc_rts_needed = final_branch           ; reuse ZP $76

.macro UPIX n, default_eor
.ident(.concat("s_upix", .string(n))):
    LDA (base),Y
.ident(.concat("smc_eor_", .string(n))):
    EOR #default_eor
    STA (base),Y
    TXA
    SBC delta_minor
    BCS :+
    ADC delta_major
    DEY
    BPL :+
    DEC base+1
    LDY #7
:   TAX
.endmacro

su_entry_lo:
    .byte <(s_upix0-1), <(s_upix1-1), <(s_upix2-1), <(s_upix3-1)
    .byte <(s_upix4-1), <(s_upix5-1), <(s_upix6-1), <(s_upix7-1)
su_entry_hi:
    .byte >(s_upix0-1), >(s_upix1-1), >(s_upix2-1), >(s_upix3-1)
    .byte >(s_upix4-1), >(s_upix5-1), >(s_upix6-1), >(s_upix7-1)

su_rts_lo:
    .byte <s_upix1, <s_upix2, <s_upix3, <s_upix4
    .byte <s_upix5, <s_upix6, <s_upix7, <s_upix0
su_rts_hi:
    .byte >s_upix1, >s_upix2, >s_upix3, >s_upix4
    .byte >s_upix5, >s_upix6, >s_upix7, >s_upix0

su_write_rts:
    LDA smc_rts_needed
    BEQ :+
smc_su_rts_sta:
    STA $FFFF
:   RTS

shallow_setup:
    STA delta_major

    LDA x1
    ORA #$07
    SBC x0
    LSR
    LSR
    LSR
    EOR #$FF
    INC A
    STA cols_left

    LDA #$B1
su_prev_restore:
    STA s_upix0

    LDA y0
    CMP y1
    BCC @su_rev

    ;=== FORWARD ===
    LDA x1
    AND #$07
    STA smc_rts_needed

    LDA x0
    AND #$07
    PHA

    BIT smc_eor_0+1
    BMI @su_common
    LDA #$80
    STA smc_eor_0+1
    LSR A
    STA smc_eor_1+1
    LSR A
    STA smc_eor_2+1
    LSR A
    STA smc_eor_3+1
    LSR A
    STA smc_eor_4+1
    LSR A
    STA smc_eor_5+1
    LSR A
    STA smc_eor_6+1
    LSR A
    STA smc_eor_7+1

    LDA #$07
    STA smc_su_advance+1

    BRA @su_common

    ;=== REVERSE ===
@su_rev:
    LDA x0
    AND #$07
    EOR #$07
    STA smc_rts_needed

    LDA x1
    AND #$07
    EOR #$07
    PHA

    LDA x1
    STA x0
    LDA y1
    STA y0

    BIT smc_eor_0+1
    BPL @su_common
    LDA #$01
    STA smc_eor_0+1
    ASL A
    STA smc_eor_1+1
    ASL A
    STA smc_eor_2+1
    ASL A
    STA smc_eor_3+1
    ASL A
    STA smc_eor_4+1
    ASL A
    STA smc_eor_5+1
    ASL A
    STA smc_eor_6+1
    ASL A
    STA smc_eor_7+1

    LDA #$F7
    STA smc_su_advance+1

@su_common:
    JSR init_base

    LDX smc_rts_needed
    LDA su_rts_lo,X
    STA smc_su_rts_sta+1
    STA smc_su_rts_restore+1
    STA su_prev_restore+1
    LDA su_rts_hi,X
    STA smc_su_rts_sta+2
    STA smc_su_rts_restore+2
    STA su_prev_restore+2

    LDA #$60
    CPX #7
    BNE :+
    LDA #$00
:   STA smc_rts_needed

    LDA cols_left
    BNE @su_multi
    JSR su_write_rts

@su_multi:
    PLA
    TAX
    LDA su_entry_hi,X
    PHA
    LDA su_entry_lo,X
    PHA

    LDA delta_major
    SEC
    SBC delta_minor
    TAX

    SEC
    RTS

    UPIX 0, $80
    UPIX 1, $40
    UPIX 2, $20
    UPIX 3, $10
    UPIX 4, $08
    UPIX 5, $04
    UPIX 6, $02
    UPIX 7, $01

    LDA base
smc_su_advance:
    ADC #$07
    STA base
    INC cols_left
    BMI @su_resume
    BNE @su_complete
    JSR su_write_rts
@su_resume:
    SEC
    JMP s_upix0
@su_complete:
    LDA #$B1
smc_su_rts_restore:
    STA $FFFF
    RTS

.else

; === SHALLOW PATH (rolled) ===

shallow_setup:
    STA delta_major
    LDA x1
    ORA #$07
    SBC x0
    LSR
    LSR
    LSR
    EOR #$FF
    INC A
    STA cols_left

    LDA y0
    CMP y1
    BCC @s_rev

    LDA x1
    AND #$07
    TAX
    LDA fwd_branch_table,X
    STA final_branch
    LDA #opLSRzp
    LDX #$80
    LDY #$07
    BRA @s_common

@s_rev:
    LDA x0
    AND #$07
    TAX
    LDA rev_branch_table,X
    STA final_branch
    LDA x1
    STA x0
    LDA y1
    STA y0
    LDA #opASLzp
    LDX #$01
    LDY #$F7

@s_common:
    STA smc_s_shift
    STX smc_s_mask + 1
    STY smc_s_advance + 1
    JSR init_base

    LDA #opBCC
    STA smc_s_branch
    LDA #<(s_pixel_loop - (smc_s_branch + 2))
    STA smc_s_branch + 1
    LDA #opNOP
    STA smc_s_branch + 2

    LDA cols_left
    BNE @s_multi
    JSR s_write_final
@s_multi:
    LDA delta_major
    SEC
    SBC delta_minor
    TAX
    LDA delta_minor
    BEQ @s_keep
    DEC delta_minor
@s_keep:
    CLC

s_pixel_loop:
    LDA (base),Y
    EOR mask_zp
    STA (base),Y
    TXA
    SBC delta_minor
    BCS @s_no_y
    ADC delta_major
    DEY
    BPL @s_no_y
    DEC base+1
    LDY #7
@s_no_y:
    TAX
smc_s_shift:
    LSR mask_zp
smc_s_branch:
    BCC s_pixel_loop
    NOP

    LDA base
smc_s_advance:
    ADC #7
    STA base
smc_s_mask:
    LDA #$80
    STA mask_zp
    INC cols_left
    BMI @s_resume
    BNE @s_complete
    JSR s_write_final
@s_resume:
    CLC
    BRA s_pixel_loop
@s_complete:
    RTS

s_write_final:
    LDA final_branch
    BMI @wf_done
    STA smc_s_branch
    LDA #mask_zp
    STA smc_s_branch + 1
    LDA #<(s_pixel_loop - (smc_s_branch + 3))
    STA smc_s_branch + 2
@wf_done:
    RTS

.endif

; === STEEP PATH ===

steep_setup:
    STA delta_minor
    STY delta_major
    LDA y0
    CMP y1
    BCC @t_rev

    LDA y1
    AND #$07
    STA final_bias
    LDA y0
    ORA #$07
    SBC y1
    LSR
    LSR
    LSR
    EOR #$FF
    INC A
    STA stripes_left
    LDA #opLSRzp
    LDX #$80
    LDY #$07
    BRA @t_common

@t_rev:
    LDA y0
    AND #$07
    STA final_bias
    LDA y1
    ORA #$07
    SEC
    SBC y0
    LSR
    LSR
    LSR
    EOR #$FF
    INC A
    STA stripes_left
    LDA x1
    STA x0
    LDA y1
    STA y0
    LDA #opASLzp
    LDX #$01
    LDY #$F7

@t_common:
    STA smc_t_shift
    STX smc_t_mask + 1
    STY smc_t_col_adv + 1
    JSR init_base

    LDA stripes_left
    BNE @t_multi
    LDA base
    CLC
    ADC final_bias
    STA base
    TYA
    SEC
    SBC final_bias
    TAY
@t_multi:
    LDA delta_major
    SEC
    SBC delta_minor
    TAX

t_pixel_loop:
    LDA (base),Y
    EOR mask_zp
    STA (base),Y
    TXA
    SBC delta_minor
    BCS t_no_x
    ADC delta_major
smc_t_shift:
    LSR mask_zp
    BCC t_xdone
    PHA
    LDA base
smc_t_col_adv:
    ADC #$07
    STA base
smc_t_mask:
    LDA #$80
    STA mask_zp
    PLA
t_xdone:
    SEC
t_no_x:
    TAX
    DEY
    BPL t_pixel_loop

    INC stripes_left
    BMI @t_normal
    BNE @t_complete
    DEC base+1
    LDA base
    CLC
    ADC final_bias
    STA base
    LDA #7
    SEC
    SBC final_bias
    TAY
    SEC
    BRA t_pixel_loop
@t_normal:
    DEC base+1
    LDY #7
    SEC
    BRA t_pixel_loop
@t_complete:
    RTS

;=======================================
; VERTICAL PATH — dx=0, major axis Y only
; Unrolled 8 pixels/stripe, 15 cycles/pixel
;=======================================

;--- Macro: one vertical pixel iteration ---
.macro VPIX n
.ident(.concat("v_iter", .string(n))):
    LDA (base),Y
.ident(.concat("smc_v_eor_", .string(n))):
    EOR #$80                ; SMC'd: mask_init_table[x0 & 7]
    STA (base),Y
    DEY                     ; 15 cycles/pixel
.endmacro

;--- Entry address tables ---
v_entry_lo:
    .byte <v_iter0, <v_iter1, <v_iter2, <v_iter3
    .byte <v_iter4, <v_iter5, <v_iter6, <v_iter7
v_entry_hi:
    .byte >v_iter0, >v_iter1, >v_iter2, >v_iter3
    .byte >v_iter4, >v_iter5, >v_iter6, >v_iter7

;--- Vertical setup ---
; Entry: A=0 (dx), Y=|dy|. x0, y0, x1, y1 set.
vertical_setup:
    ; 1. Normalize: ensure y0 >= y1 (draw downward with DEY)
    LDA y0
    CMP y1
    BCS @v_sorted
    LDX y1
    STX y0
    STA y1
@v_sorted:

    ; 2. SMC 8 EOR immediates with mask_init_table[x0 & 7]
    LDA x0
    AND #$07
    TAX
    LDA mask_init_table,X
    STA smc_v_eor_0+1
    STA smc_v_eor_1+1
    STA smc_v_eor_2+1
    STA smc_v_eor_3+1
    STA smc_v_eor_4+1
    STA smc_v_eor_5+1
    STA smc_v_eor_6+1
    STA smc_v_eor_7+1

    ; 3. Compute base (inline, no init_base needed — mask_zp not used)
    LDA y0
    LSR
    LSR
    LSR
    CLC
    ADC screen_page
    STA base+1
    LDA x0
    AND #$F8
    STA base

    ; 4. Compute stripes_left and final_bias
    ;    final_bias = y1 & 7
    LDA y1
    AND #$07
    STA final_bias

    ;    stripes_left = -((y0>>3) - (y1>>3))
    LDA y0
    ORA #$07
    SEC
    SBC y1                  ; (y0|7) - y1
    LSR
    LSR
    LSR                     ; = (y0>>3) - (y1>>3)
    EOR #$FF
    INC A
    STA stripes_left

    ; Y = y0 & 7
    LDA y0
    AND #$07
    TAY

    ; 5. Branch single vs multi stripe
    LDA stripes_left
    BNE @v_multi

    ; --- Single-stripe ---
    ; base += final_bias, Y = (y0&7) - final_bias
    LDA base
    CLC
    ADC final_bias
    STA base
    TYA
    SEC
    SBC final_bias
    TAY

    ; entry_index = Y EOR $07 (= 7 - Y = skip count)
    EOR #$07
    TAX
    LDA v_entry_lo,X
    STA smc_v_entry+1
    LDA v_entry_hi,X
    STA smc_v_entry+2
    JMP @v_go

@v_multi:
    ; Precompute final entry: v_entry[final_bias] → smc_v_final
    LDX final_bias
    LDA v_entry_lo,X
    STA smc_v_final+1
    LDA v_entry_hi,X
    STA smc_v_final+2

    ; Compute first entry: entry_index = 7 - (y0&7)
    TYA                     ; Y = y0 & 7
    EOR #$07                ; = 7 - (y0&7)
    TAX
    LDA v_entry_lo,X
    STA smc_v_entry+1
    LDA v_entry_hi,X
    STA smc_v_entry+2

    ; Y already = y0 & 7

@v_go:
smc_v_entry:
    JMP v_iter0             ; SMC'd to correct first-stripe entry

;--- Unrolled vertical pixel loop ---
    VPIX 0
    VPIX 1
    VPIX 2
    VPIX 3
    VPIX 4
    VPIX 5
    VPIX 6
    VPIX 7

    ; --- Stripe transition (after v_iter7's DEY, Y = $FF) ---
    INC stripes_left
    BMI @v_full_stripe      ; stripes_left < 0: more full stripes
    BEQ @v_final_stripe     ; stripes_left = 0: entering final stripe
@v_complete:
    RTS

@v_full_stripe:
    DEC base+1
    LDY #7
    BRA v_iter0

@v_final_stripe:
    DEC base+1
    LDA base
    CLC
    ADC final_bias
    STA base
    LDA #7
    SEC
    SBC final_bias
    TAY
smc_v_final:
    JMP v_iter0             ; SMC'd during setup to v_entry[final_bias]

init_base:
    LDA x0
    AND #$07
    TAX
    LDA mask_init_table,X
    STA mask_zp
    LDA y0
    LSR
    LSR
    LSR
    CLC
    ADC screen_page
    STA base+1
    LDA x0
    AND #$F8
    STA base
    LDA y0
    AND #$07
    TAY
    RTS
