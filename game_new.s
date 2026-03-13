; game.s — Battlezone-style wireframe 3D game for BBC Micro
; Assembled with ca65: ca65 --cpu 65C02 game.s -o game.o
; Linked with ld65:    ld65 -C linker.cfg game.o -o game.bin
;
; Loads and runs at $3000. Double-buffered at $4000/$6000.
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
KEYBOARD    = $FC00

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
num_prev_0      = $9D       ; prev line count for buffer 0
num_prev_1      = $9E       ; prev line count for buffer 1
rel_x           = $9F       ; relative world X (pre-rotation)
rel_z           = $A0       ; relative world Z (pre-rotation)

; Projection precision
recip_lo_val    = $A4       ; fractional recip correction for current vertex
center_vx_frac  = $A5       ; fractional center view X (0.8 format)
rot_hx_frac     = $A6       ; fractional h*cos corner offset
rot_kx_frac     = $A7       ; fractional h*sin corner offset
vx_frac         = $A8       ; per-vertex fractional X (passed to projection)

; Rotation results
rot_hx          = $A1       ; (h * cos) >> 7
rot_kx          = $A2       ; (h * sin) >> 7
rot_hz          = $A3       ; -(h * sin) >> 7

; === RAM buffers ($0200-$03FF) ===
; Projected vertex buffer (8 max per object, overwritten each object)
proj_x          = $0200     ; 8 bytes: projected screen X
proj_y          = $0208     ; 8 bytes: projected screen Y
proj_z          = $0210     ; 8 bytes: view-space Z (0 = invalid)

; Line buffers (4 bytes per line: x0, y0, x1, y1)
new_lines       = $0220     ; up to 32 lines (128 bytes) → $0220-$029F
prev_lines_0    = $02A0     ; buffer 0 prev lines (128 bytes) → $02A0-$031F
prev_lines_1    = $0320     ; buffer 1 prev lines (128 bytes) → $0320-$039F

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
    STA num_prev_0
    STA num_prev_1
    STA num_new_lines

    ; Player starts at (128, 64) — in middle X, behind objects
    LDA #128
    STA player_x_hi
    LDA #64
    STA player_z_hi

    LDA #NUM_OBJECTS
    STA num_objects

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
    JSR build_scene
    JSR erase_prev_lines
    JSR draw_new_lines
    JSR save_prev_lines
    JSR wait_vsync
    JSR flip_buffers
    JMP main_loop

; =====================================================================
; Input handling
; =====================================================================

read_input:
    LDA KEYBOARD

    ; Bit 0: Z = rotate left (angle increases)
    BIT #$01
    BEQ @no_left
    LDA player_angle
    CLC
    ADC #2
    STA player_angle
    LDA KEYBOARD
@no_left:

    ; Bit 1: X = rotate right (angle decreases)
    BIT #$02
    BEQ @no_right
    LDA player_angle
    SEC
    SBC #2
    STA player_angle
    LDA KEYBOARD
@no_right:

    ; Bit 2: Return = move forward
    BIT #$04
    BEQ @no_forward
    JSR move_forward
@no_forward:
    RTS

move_forward:
    LDX player_angle

    ; X movement: sin(angle) >> 1 added to 8.8 fixed point position
    LDA sin_table,X
    CMP #$80            ; set carry if negative (arithmetic shift right)
    ROR A
    CLC
    ADC player_x_lo
    STA player_x_lo
    ; Sign-extend: if sin was negative, add $FF to hi byte (= subtract 1)
    LDA player_x_hi
    ADC #0              ; add carry from low-byte add
    LDY sin_table,X
    BPL @sin_pos
    DEC A               ; sign extension for negative sin
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

erase_prev_lines:
    LDA back_buf_idx
    BNE @erase_buf1

    LDX num_prev_0
    BEQ @erase_done
    LDY #0
@erase_loop_0:
    LDA prev_lines_0,Y
    STA x0
    LDA prev_lines_0+1,Y
    STA y0
    LDA prev_lines_0+2,Y
    STA x1
    LDA prev_lines_0+3,Y
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
    LDX num_prev_1
    BEQ @erase_done
    LDY #0
@erase_loop_1:
    LDA prev_lines_1,Y
    STA x0
    LDA prev_lines_1+1,Y
    STA y0
    LDA prev_lines_1+2,Y
    STA x1
    LDA prev_lines_1+3,Y
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

draw_new_lines:
    LDX num_new_lines
    BEQ @draw_done
    LDY #0
@draw_loop:
    LDA new_lines,Y
    STA x0
    LDA new_lines+1,Y
    STA y0
    LDA new_lines+2,Y
    STA x1
    LDA new_lines+3,Y
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
    BNE @draw_loop
@draw_done:
    RTS

save_prev_lines:
    LDA back_buf_idx
    BNE @save_buf1

    LDA num_new_lines
    STA num_prev_0
    TAX
    BEQ @save_done
    LDY #0
@save_loop_0:
    LDA new_lines,Y
    STA prev_lines_0,Y
    LDA new_lines+1,Y
    STA prev_lines_0+1,Y
    LDA new_lines+2,Y
    STA prev_lines_0+2,Y
    LDA new_lines+3,Y
    STA prev_lines_0+3,Y
    INY
    INY
    INY
    INY
    DEX
    BNE @save_loop_0
    BRA @save_done

@save_buf1:
    LDA num_new_lines
    STA num_prev_1
    TAX
    BEQ @save_done
    LDY #0
@save_loop_1:
    LDA new_lines,Y
    STA prev_lines_1,Y
    LDA new_lines+1,Y
    STA prev_lines_1+1,Y
    LDA new_lines+2,Y
    STA prev_lines_1+2,Y
    LDA new_lines+3,Y
    STA prev_lines_1+3,Y
    INY
    INY
    INY
    INY
    DEX
    BNE @save_loop_1

@save_done:
    RTS

; =====================================================================
; Scene building
; =====================================================================

build_scene:
    LDA #0
    STA num_new_lines

    ; Horizon line
    JSR emit_horizon
    ; Crosshair
    JSR emit_crosshair
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
    RTS

emit_horizon:
    LDX num_new_lines
    TXA
    ASL A
    ASL A
    TAX
    LDA #0
    STA new_lines,X
    LDA #HORIZON_Y
    STA new_lines+1,X
    LDA #255
    STA new_lines+2,X
    LDA #HORIZON_Y
    STA new_lines+3,X
    INC num_new_lines
    RTS

emit_crosshair:
    ; Horizontal: (124, HORIZON_Y) to (132, HORIZON_Y)
    LDX num_new_lines
    TXA
    ASL A
    ASL A
    TAX
    LDA #124
    STA new_lines,X
    LDA #HORIZON_Y
    STA new_lines+1,X
    LDA #132
    STA new_lines+2,X
    LDA #HORIZON_Y
    STA new_lines+3,X
    INC num_new_lines

    ; Vertical: (128, HORIZON_Y-4) to (128, HORIZON_Y+4)
    LDX num_new_lines
    TXA
    ASL A
    ASL A
    TAX
    LDA #128
    STA new_lines,X
    LDA #(HORIZON_Y - 4)
    STA new_lines+1,X
    LDA #128
    STA new_lines+2,X
    LDA #(HORIZON_Y + 4)
    STA new_lines+3,X
    INC num_new_lines
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
    JSR smul8x8         ; full 16-bit: math_res_hi:math_res_lo
    LDA math_res_hi
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

    ; --- view_z = (-rel_x * sin + rel_z * cos) >> 7 ---
    ; = (rel_z * cos - rel_x * sin) >> 7
    LDA rel_z
    STA math_a
    LDA cos_table,Y
    STA math_b
    JSR smul8x8_s7
    LDA math_res_hi
    PHA                 ; save rel_z * cos >> 7

    LDA rel_x
    STA math_a
    LDA sin_table,Y
    STA math_b
    JSR smul8x8_s7
    PLA
    SEC
    SBC math_res_hi     ; view_z = (rel_z*cos - rel_x*sin) >> 7
    STA temp1           ; rotated center Z (signed 8-bit)

    ; Check if object is in front of camera (Z >= 3)
    BMI @obj_behind      ; negative Z → behind camera
    CMP #3
    BCS @obj_in_front
@obj_behind:
    PLA                  ; discard type from stack
    RTS
@obj_in_front:

    ; --- Compute side face visibility (shared by cube and pyramid) ---
    LDA cur_obj
    ASL A
    ASL A
    ASL A
    TAX

    LDA #0
    STA face_vis

    ; Face 0 (front, +Z): visible if player_z > obj_z
    LDA player_z_hi
    CMP obj_table+1,X
    BEQ @no_f0
    BCC @no_f0
    LDA #$01
    STA face_vis
@no_f0:

    ; Face 1 (back, -Z): visible if player_z < obj_z
    LDA obj_table+1,X
    CMP player_z_hi
    BEQ @no_f1
    BCC @no_f1
    LDA face_vis
    ORA #$02
    STA face_vis
@no_f1:

    ; Face 2 (right, +X): visible if player_x > obj_x
    LDA player_x_hi
    CMP obj_table,X
    BEQ @no_f2
    BCC @no_f2
    LDA face_vis
    ORA #$04
    STA face_vis
@no_f2:

    ; Face 3 (left, -X): visible if player_x < obj_x
    LDA obj_table,X
    CMP player_x_hi
    BEQ @no_f3
    BCC @no_f3
    LDA face_vis
    ORA #$08
    STA face_vis
@no_f3:

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
    JSR smul8x8_s7
    LDA math_res_hi
    STA rot_hx          ; h*cos >> 7 (also used as rot_kz)
    LDA math_res_lo
    STA rot_hx_frac     ; fractional part

    LDA temp3
    STA math_a
    LDA sin_table,Y
    STA math_b
    JSR smul8x8_s7
    LDA math_res_hi
    STA rot_kx          ; h*sin >> 7
    LDA math_res_lo
    STA rot_kx_frac     ; fractional part
    LDA rot_kx
    EOR #$FF
    INC A
    STA rot_hz          ; -(h*sin >> 7)

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
    LDA temp1
    SEC
    SBC rot_hz
    SEC
    SBC rot_hx      ; rot_kz = rot_hx
    STA vz_temp
    LDX #0           ; base vertex
    LDY #4           ; top vertex
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
    LDA temp1
    CLC
    ADC rot_hz
    SEC
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
    LDA temp1
    CLC
    ADC rot_hz
    CLC
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
    LDA temp1
    SEC
    SBC rot_hz
    CLC
    ADC rot_hx
    STA vz_temp
    LDX #3
    LDY #7
    JSR project_corner

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
    JSR smul8x8_s7
    LDA math_res_hi
    STA rot_hx
    LDA math_res_lo
    STA rot_hx_frac

    LDA temp3
    STA math_a
    LDA sin_table,Y
    STA math_b
    JSR smul8x8_s7
    LDA math_res_hi
    STA rot_kx
    LDA math_res_lo
    STA rot_kx_frac
    LDA rot_kx
    EOR #$FF
    INC A
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
    LDA temp1
    SEC
    SBC rot_hz
    SEC
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
    LDA temp1
    CLC
    ADC rot_hz
    SEC
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
    LDA temp1
    CLC
    ADC rot_hz
    CLC
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
    LDA temp1
    SEC
    SBC rot_hz
    CLC
    ADC rot_hx
    STA vz_temp
    LDX #3
    JSR project_base_only

    ; Apex: at center position, height H
    LDA center_vx_frac
    STA vx_frac
    LDA temp0
    STA vx_temp
    LDA temp1
    STA vz_temp
    LDX #4
    JSR project_apex

    ; Emit visible edges (with face culling)
    LDX #0
@pyr_edge_loop:
    CPX #8
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
    .byte 0, 1, 2, 3,  0, 1, 2, 3
pyr_edge_v1:
    .byte 1, 2, 3, 0,  4, 4, 4, 4
; Face associations: base edges → one side face; apex edges → two side faces
; face0=front(+Z)=$01, face1=back(-Z)=$02, face2=right(+X)=$04, face3=left(-X)=$08
pyr_edge_faces:
    .byte $02, $04, $01, $08, $0A, $06, $05, $09

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

    ; Check view Z (use trampoline for far branch)
    LDA vz_temp
    BMI @pc_inv_jmp
    CMP #5
    BCS @pc_z_ok
@pc_inv_jmp:
    JMP @pc_invalid
@pc_z_ok:

    ; Mark both vertices valid
    LDX pc_base_idx
    STA proj_z,X
    LDX pc_top_idx
    STA proj_z,X

    ; Look up recip (integer + fractional correction)
    TAX
    LDA recip_table,X
    STA recip_val
    LDA recip_lo_table,X
    STA recip_lo_val

    ; --- Project screen X (with fractional correction) ---
    ; Main displacement: vx * recip_hi
    LDA vx_temp
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    ; Save main displacement
    LDA math_res_lo
    STA temp2            ; main_lo
    LDA math_res_hi
    PHA                  ; main_hi on stack

    ; Fractional correction: (vx * recip_lo) >> 7
    LDA vx_temp
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8_s7       ; math_res_hi = signed correction

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
    JSR smul8x8_s7       ; math_res_hi = correction (0..126)

    ; Add to displacement (always positive)
    CLC
    LDA temp2
    ADC math_res_hi
    STA math_res_lo
    PLA
    ADC #0
    STA math_res_hi

    ; 16-bit: screen_x = 128 + displacement, clamped to 0-255
    CLC
    LDA #128
    ADC math_res_lo
    PHA                 ; save lo byte
    LDA #0
    ADC math_res_hi
    BEQ @pc_x_ok
    PLA                 ; discard lo — vertex off-screen, invalidate
    JMP @pc_invalid
@pc_x_ok:
    PLA                 ; A = valid screen X
    ; Store same X for both base and top
    LDX pc_base_idx
    STA proj_x,X
    LDX pc_top_idx
    STA proj_x,X

    ; --- Project base screen Y ---
    ; base_y = HORIZON_Y + 3 * recip_val
    LDA recip_val
    ASL A
    BCS @pc_base_clamp
    CLC
    ADC recip_val
    BCS @pc_base_clamp
    CLC
    ADC #HORIZON_Y
    BCS @pc_base_clamp
    STA base_y_temp
    BRA @pc_store_base

@pc_base_clamp:
    LDA #255
    STA base_y_temp

@pc_store_base:
    LDX pc_base_idx
    LDA base_y_temp
    STA proj_y,X

    ; --- Project top screen Y (with fractional correction) ---
    ; Main: H * recip_hi
    LDA obj_height
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    LDA math_res_hi
    BNE @pc_top_clamp       ; main height > 255 → top off-screen
    ; Save main height
    LDA math_res_lo
    STA temp2

    ; Fractional correction: (H * recip_lo) >> 7
    LDA obj_height
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8_s7           ; math_res_hi = signed correction

    ; Total height = main + correction
    LDA math_res_hi
    BPL @pc_hc_pos
    ; Negative correction (can't underflow — total always >= 0)
    CLC
    ADC temp2
    BRA @pc_sub_height
@pc_hc_pos:
    CLC
    ADC temp2
    BCS @pc_top_clamp        ; overflow → top off-screen
@pc_sub_height:
    ; A = total height displacement
    STA temp2
    LDA base_y_temp
    SEC
    SBC temp2
    BCC @pc_top_clamp
    LDX pc_top_idx
    STA proj_y,X
    RTS

@pc_top_clamp:
    LDX pc_top_idx
    LDA #0
    STA proj_y,X
    RTS

@pc_invalid:
    LDX pc_base_idx
    LDA #0
    STA proj_z,X
    LDX pc_top_idx
    STA proj_z,X
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
    CMP #5
    BCS @pb_z_ok
@pb_inv_jmp:
    JMP @pb_invalid
@pb_z_ok:
    STA proj_z,X

    TAY
    LDA recip_table,Y
    STA recip_val
    LDA recip_lo_table,Y
    STA recip_lo_val

    ; Project X (with fractional correction)
    LDA vx_temp
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    ; Save main displacement
    LDA math_res_lo
    STA temp2
    LDA math_res_hi
    PHA                  ; main_hi

    ; Fractional correction
    LDA vx_temp
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8_s7

    ; Add correction to main
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
    JSR smul8x8_s7

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
    PHA
    LDA #0
    ADC math_res_hi
    BEQ @pb_x_ok
    PLA                 ; X overflow — invalidate vertex
    LDX pc_base_idx
    LDA #0
    STA proj_z,X
    RTS
@pb_x_ok:
    PLA
    STA proj_x,X

@pb_y:
    ; base_y = HORIZON_Y + 3 * recip
    LDA recip_val
    ASL A
    BCS @pb_y_clamp
    CLC
    ADC recip_val
    BCS @pb_y_clamp
    CLC
    ADC #HORIZON_Y
    BCS @pb_y_clamp
    STA proj_y,X
    RTS
@pb_y_clamp:
    LDA #255
    STA proj_y,X
    RTS

@pb_invalid:
    LDA #0
    STA proj_z,X
    RTS

; Project pyramid apex (at center, height H)
; Input: vx_temp, vz_temp, X = vertex index (4)
project_apex:
    STX pc_base_idx     ; save vertex index (smul8x8 clobbers X)
    LDA vz_temp
    BMI @pa_inv_jmp
    CMP #5
    BCS @pa_z_ok
@pa_inv_jmp:
    JMP @pa_invalid
@pa_z_ok:
    STA proj_z,X

    TAY
    LDA recip_table,Y
    STA recip_val
    LDA recip_lo_table,Y
    STA recip_lo_val

    ; Project X (with fractional correction)
    LDA vx_temp
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    LDA math_res_lo
    STA temp2
    LDA math_res_hi
    PHA

    LDA vx_temp
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8_s7

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
    JSR smul8x8_s7

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
    PHA
    LDA #0
    ADC math_res_hi
    BEQ @pa_x_ok
    PLA                 ; X overflow — invalidate vertex
    LDX pc_base_idx
    LDA #0
    STA proj_z,X
    RTS
@pa_x_ok:
    PLA
    STA proj_x,X

@pa_y:
    ; apex_y = (HORIZON_Y + 3*recip) - H*recip
    ; Compute base_y first
    LDA recip_val
    ASL A
    BCS @pa_base_max
    CLC
    ADC recip_val
    BCS @pa_base_max
    CLC
    ADC #HORIZON_Y
    BCS @pa_base_max
    STA base_y_temp
    BRA @pa_height
@pa_base_max:
    LDA #255
    STA base_y_temp

@pa_height:
    ; Main: H * recip_hi
    LDA obj_height
    STA math_a
    LDA recip_val
    STA math_b
    JSR smul8x8
    LDA math_res_hi
    BNE @pa_y_clamp          ; main height > 255 → clamp
    LDA math_res_lo
    STA temp2

    ; Fractional correction: (H * recip_lo) >> 7
    LDA obj_height
    STA math_a
    LDA recip_lo_val
    STA math_b
    JSR smul8x8_s7

    ; Total height = main + correction
    LDA math_res_hi
    BPL @pa_hc_pos
    CLC
    ADC temp2
    BRA @pa_sub_height
@pa_hc_pos:
    CLC
    ADC temp2
    BCS @pa_y_clamp
@pa_sub_height:
    STA temp2
    LDA base_y_temp
    SEC
    SBC temp2
    BCC @pa_y_clamp
    LDX pc_base_idx
    STA proj_y,X
    RTS
@pa_y_clamp:
    LDX pc_base_idx
    LDA #0
    STA proj_y,X
    RTS

@pa_invalid:
    LDA #0
    STA proj_z,X
    RTS

; =====================================================================
; Emit edge — add projected edge to new_lines
; Y = vertex 0 index, X = vertex 1 index
; Uses temp2, recip_val as scratch (safe: not needed during emit)
; =====================================================================

emit_edge:
    LDA num_new_lines
    CMP #30
    BCS @ee_done

    ; Save vertex 0 coords to ZP
    LDA proj_x,Y
    STA temp2
    LDA proj_y,Y
    STA recip_val

    ; Compute buffer offset
    LDA num_new_lines
    ASL A
    ASL A               ; * 4
    TAY                 ; Y = offset into new_lines

    ; Write line: v0_x, v0_y, proj_x[v1], proj_y[v1]
    LDA temp2
    STA new_lines,Y
    LDA recip_val
    STA new_lines+1,Y
    LDA proj_x,X
    STA new_lines+2,Y
    LDA proj_y,X
    STA new_lines+3,Y
    INC num_new_lines
@ee_done:
    RTS

; =====================================================================
; Signed 8x8 → 16-bit multiply
; Input:  math_a (signed), math_b (signed)
; Output: math_res_hi:math_res_lo (signed 16-bit)
; =====================================================================

smul8x8:
    LDA math_a
    EOR math_b
    PHP                 ; save sign (N flag)

    LDA math_a
    BPL @a_pos
    EOR #$FF
    INC A
    STA math_a
@a_pos:
    LDA math_b
    BPL @b_pos
    EOR #$FF
    INC A
    STA math_b
@b_pos:

    ; Unsigned 8x8 multiply: shift-and-add
    LDA #0
    STA math_res_hi
    LDX #8
@mul_loop:
    LSR math_a
    BCC @no_add
    CLC
    ADC math_b
@no_add:
    ROR A
    ROR math_res_hi
    DEX
    BNE @mul_loop

    ; A = high byte, math_res_hi = low byte
    LDX math_res_hi
    STX math_res_lo
    STA math_res_hi

    ; Apply sign
    PLP
    BPL @done
    ; Negate 16-bit
    LDA math_res_lo
    EOR #$FF
    CLC
    ADC #1
    STA math_res_lo
    LDA math_res_hi
    EOR #$FF
    ADC #0
    STA math_res_hi
@done:
    RTS

; smul8x8_s7: signed multiply then >>7 (for sin/cos scaling)
; After multiply, shift result left 1 (equivalent to taking >>7 instead of >>8)
; Result: math_res_hi contains the >>7 scaled value
smul8x8_s7:
    JSR smul8x8
    ASL math_res_lo
    ROL math_res_hi
    RTS

; =====================================================================
; Object table
; Format: world_x, world_z, type(0=cube,1=pyr), half_size, height, 0, 0, 0
; Player starts at (128, 64). Objects ahead (higher Z values).
; =====================================================================

NUM_OBJECTS = 6

obj_table:
    ; Object 0: cube directly ahead
    .byte 128, 90, 0, 4, 8, 0, 0, 0
    ; Object 1: cube ahead-right
    .byte 145, 100, 0, 3, 6, 0, 0, 0
    ; Object 2: pyramid ahead-left
    .byte 110, 95, 1, 3, 12, 0, 0, 0
    ; Object 3: cube far ahead
    .byte 130, 130, 0, 5, 7, 0, 0, 0
    ; Object 4: pyramid far right
    .byte 160, 110, 1, 4, 14, 0, 0, 0
    ; Object 5: cube near-left
    .byte 115, 80, 0, 3, 5, 0, 0, 0

; =====================================================================
; Lookup tables
; =====================================================================

.include "tables.inc"

; =====================================================================
; Line rasterizer (Bresenham)
; =====================================================================

mask_init_table:
    .byte $80, $40, $20, $10, $08, $04, $02, $01

fwd_branch_table:
    .byte opBBR6, opBBR5, opBBR4, opBBR3, opBBR2, opBBR1, opBBR0
rev_branch_table:
    .byte opBCC, opBBR7, opBBR6, opBBR5, opBBR4, opBBR3, opBBR2, opBBR1

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
    STY delta_minor
    CMP delta_minor
    BCS shallow_setup
    JMP steep_setup

; === SHALLOW PATH ===

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
