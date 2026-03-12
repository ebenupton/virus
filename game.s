; game.s — Real-time perspective grid with camera translation for BBC Micro
; Assembled with ca65: ca65 --cpu 65C02 game.s -o game.o
; Linked with ld65:    ld65 -C linker.cfg game.o -o game.bin
;
; Loads and runs at $0600. Double-buffered at $3000/$5800 (10K each).
; MODE 2-like video: 128×160, 4bpp, 512-byte stripes.
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

; === Include ZP API files ===
.include "raster_zp.inc"
.include "math_zp.inc"
.include "grid_zp.inc"
.include "object_zp.inc"

; === Zero page: video (forward-declared for ZP addressing) ===
back_buf_idx    = $10

; === Zero page: camera state ($20-$23) ===
cam_x_lo        = $20       ; 8.8 fixed-point X position (low byte)
cam_x_hi        = $21       ; 8.8 fixed-point X position (high byte)
cam_z_lo        = $22       ; 8.8 fixed-point Z position (low byte)
cam_z_hi        = $23       ; 8.8 fixed-point Z position (high byte)

; === Constants ===
SCREEN_W    = 128            ; pixels wide (4bpp, 2 pixels per byte)
SCREEN_H    = 160            ; pixels tall (20 character rows)

; BBC Micro key scan codes
KEY_Z       = $61
KEY_X       = $42
KEY_RETURN  = $49
KEY_SPACE   = $62
KEY_K       = $46
KEY_M       = $65
KEY_L       = $56

; Camera constants
CAM_HEIGHT_LO   = $80        ; camera height 1.5 in 8.8 = $0180
CAM_HEIGHT_HI   = $01
CAM_Z_BEHIND    = $0240      ; camera 2.25 units behind ship (= grid centre z)

; Physics constants (12.5 fps, 1 grid cell = $40 in 8.8)
GRAVITY_ACCEL   = 52          ; 0.5 cells/s²
THRUST_ACCEL    = 104         ; 2× gravity

; Ship orientation state
ship_yaw        = $24        ; Y-axis rotation angle
ship_roll      = $25        ; X-axis roll angle

; Velocity: 24-bit signed (hi:lo:frac) per axis
vel_x_hi        = $26
vel_x_lo        = $27
vel_x_frac      = $28
vel_y_hi        = $29
vel_y_lo        = $2A
vel_y_frac      = $2B
vel_z_hi        = $2C
vel_z_lo        = $2D
vel_z_frac      = $2E

; Sub-pixel position accumulators
pos_x_frac      = $54
pos_y_frac      = $55
pos_z_frac      = $56

; Camera Y (8.8 fixed-point, computed = ship_y + 1.5)
cam_y_lo        = $57
cam_y_hi        = $58

; =====================================================================
; Entry point ($0600)
; =====================================================================

entry:
    SEI

    ; Zero status bar rows that clear_screen skips (real hardware init)
    LDY #0
    TYA
@clr_status:
    STA $3000,Y
    STA $3100,Y
    STA $5800,Y
    STA $5900,Y
    INY
    BNE @clr_status

    JSR init_screen
    JSR init_status
    JSR draw_map              ; blit minimap to buf1 (raster_page=$58 from init)
    LDA #$30
    STA raster_page
    JSR draw_map              ; blit minimap to buf0
    LDA #$58
    STA raster_page           ; restore to buf1 (back buffer)

    ; Initialize rotation angle and orientation
    STZ obj_rot_angle
    STZ ship_yaw
    STZ ship_roll

    ; Initialize velocities to zero
    STZ vel_x_hi
    STZ vel_x_lo
    STZ vel_x_frac
    STZ vel_y_hi
    STZ vel_y_lo
    STZ vel_y_frac
    STZ vel_z_hi
    STZ vel_z_lo
    STZ vel_z_frac

    ; Initialize position fraction accumulators
    STZ pos_x_frac
    STZ pos_y_frac
    STZ pos_z_frac

    ; Initialize camera: follow ship at (4, 0, 4)
    STZ cam_x_lo
    LDA #$04                ; ship_x_hi = 4
    STA cam_x_hi
    LDA #<($0400 - CAM_Z_BEHIND)  ; cam_z = ship_z - CAM_Z_BEHIND
    STA cam_z_lo
    LDA #>($0400 - CAM_Z_BEHIND)
    STA cam_z_hi
    LDA #CAM_HEIGHT_LO          ; cam_y = 0 + 1.5 = $0180
    STA cam_y_lo
    LDA #CAM_HEIGHT_HI
    STA cam_y_hi

; =====================================================================
; Main loop
; =====================================================================

main_loop:
    JSR update_camera
    JSR update_physics
    JSR clear_screen
    JSR draw_grid

    ; Default bbox: nothing drawn by object (overwritten if draw_object runs)
    LDA #160
    STA obj_bb_min_sy

    LDA ship_yaw
    STA obj_rot_angle
    LDA ship_roll
    STA obj_roll_angle
    LDA #<obj_ship
    STA obj_ptr
    LDA #>obj_ship
    STA obj_ptr+1

    LDY #OBJ_WORLD_SHIP
    JSR setup_obj_view
    BCS @skip_ship
    JSR draw_object
@skip_ship:

    ; Combine grid + object dirty tops → save for this buffer's next clear
    LDA grid_min_sy
    CMP obj_bb_min_sy
    BCC @use_grid
    LDA obj_bb_min_sy
@use_grid:
    LDX back_buf_idx
    STA dirty_top_buf0,X

    JSR draw_status
    JSR wait_vsync
    JSR flip_buffers
    JMP main_loop

; =====================================================================
; Update camera — VIA key scanning, direct X/Z translation
; =====================================================================

update_camera:
    LDA #$7F
    STA SYS_VIA_DDRA        ; bits 0-6 output, bit 7 input

    ; Z key → yaw right (ship_yaw -= 4)
    LDA #KEY_Z
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_yaw_left
    LDA ship_yaw
    SEC
    SBC #4
    STA ship_yaw
@no_yaw_left:

    ; X key → yaw left (ship_yaw += 4)
    LDA #KEY_X
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_yaw_right
    LDA ship_yaw
    CLC
    ADC #4
    STA ship_yaw
@no_yaw_right:

    ; K key → roll left (ship_roll += 4)
    LDA #KEY_K
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_roll_up
    LDA ship_roll
    CLC
    ADC #4
    STA ship_roll
@no_roll_up:

    ; M key → roll right (ship_roll -= 4)
    LDA #KEY_M
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_roll_down
    LDA ship_roll
    SEC
    SBC #4
    STA ship_roll
@no_roll_down:
    RTS

; =====================================================================
; Update physics — gravity, thrust, drag, position, ground clamp, camera
; =====================================================================

update_physics:
    ; 1. Gravity (always — subtract from Y velocity)
    LDA #<(-GRAVITY_ACCEL)   ; #$CC
    LDX #3                   ; Y axis
    JSR add_accel

    ; 2. Thrust (if L key pressed)
    LDA #KEY_L
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_thrust

    ; Precompute trig values into $80-$83
    LDX ship_roll
    TXA
    CLC
    ADC #64
    TAX
    LDA sin_table,X          ; cos(roll)
    STA $80
    LDX ship_roll
    LDA sin_table,X          ; sin(roll)
    STA $81
    LDX ship_yaw
    TXA
    CLC
    ADC #64
    TAX
    LDA sin_table,X          ; cos(yaw)
    STA $82
    LDX ship_yaw
    LDA sin_table,X          ; sin(yaw)
    STA $83

    ; thrust_y = (cos(roll) * THRUST_ACCEL) >> 7
    LDA $80
    STA math_a
    LDA #THRUST_ACCEL
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    LDA math_res_hi
    ROL A
    LDX #3                   ; Y axis
    JSR add_accel

    ; horiz = (sin(roll) * THRUST_ACCEL) >> 7
    LDA $81
    STA math_a
    LDA #THRUST_ACCEL
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    LDA math_res_hi
    ROL A
    STA $84                  ; save horiz

    ; thrust_x = (sin(yaw) * horiz) >> 7
    LDA $83
    STA math_a
    LDA $84
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    LDA math_res_hi
    ROL A
    LDX #0                   ; X axis
    JSR add_accel

    ; thrust_z = (cos(yaw) * horiz) >> 7
    LDA $82
    STA math_a
    LDA $84
    STA math_b
    JSR smul8x8
    ASL math_res_lo
    LDA math_res_hi
    ROL A
    LDX #6                   ; Z axis
    JSR add_accel

@no_thrust:
    ; 3. Drag (all 3 axes)
    LDX #0
    JSR apply_drag
    LDX #3
    JSR apply_drag
    LDX #6
    JSR apply_drag

    ; 4. Position update (24-bit add per axis)
    ; X axis
    CLC
    LDA pos_x_frac
    ADC vel_x_frac
    STA pos_x_frac
    LDA obj_world_pos+OBJ_WORLD_SHIP+0
    ADC vel_x_lo
    STA obj_world_pos+OBJ_WORLD_SHIP+0
    LDA obj_world_pos+OBJ_WORLD_SHIP+1
    ADC vel_x_hi
    STA obj_world_pos+OBJ_WORLD_SHIP+1

    ; Y axis
    CLC
    LDA pos_y_frac
    ADC vel_y_frac
    STA pos_y_frac
    LDA obj_world_pos+OBJ_WORLD_SHIP+2
    ADC vel_y_lo
    STA obj_world_pos+OBJ_WORLD_SHIP+2
    LDA obj_world_pos+OBJ_WORLD_SHIP+3
    ADC vel_y_hi
    STA obj_world_pos+OBJ_WORLD_SHIP+3

    ; Z axis
    CLC
    LDA pos_z_frac
    ADC vel_z_frac
    STA pos_z_frac
    LDA obj_world_pos+OBJ_WORLD_SHIP+4
    ADC vel_z_lo
    STA obj_world_pos+OBJ_WORLD_SHIP+4
    LDA obj_world_pos+OBJ_WORLD_SHIP+5
    ADC vel_z_hi
    STA obj_world_pos+OBJ_WORLD_SHIP+5

    ; 5. Ground clamp: use terrain_y computed by project_grid
    LDA obj_world_pos+OBJ_WORLD_SHIP+3    ; y_hi
    BMI @do_clamp                          ; negative → below ground
    BNE @above_ground                      ; hi > 0 → above
    LDA obj_world_pos+OBJ_WORLD_SHIP+2    ; y_lo
    CMP terrain_y
    BCS @above_ground
@do_clamp:
    LDA terrain_y
    STA obj_world_pos+OBJ_WORLD_SHIP+2
    STZ obj_world_pos+OBJ_WORLD_SHIP+3
    STZ pos_y_frac
    STZ vel_y_hi
    STZ vel_y_lo
    STZ vel_y_frac
@above_ground:

    ; 6. Camera follow
    ; cam_x = ship_x
    LDA obj_world_pos+OBJ_WORLD_SHIP+0
    STA cam_x_lo
    LDA obj_world_pos+OBJ_WORLD_SHIP+1
    STA cam_x_hi
    ; cam_z = ship_z - CAM_Z_BEHIND
    LDA obj_world_pos+OBJ_WORLD_SHIP+4
    SEC
    SBC #<CAM_Z_BEHIND
    STA cam_z_lo
    LDA obj_world_pos+OBJ_WORLD_SHIP+5
    SBC #>CAM_Z_BEHIND
    STA cam_z_hi

    ; 7. Camera Y = ship_y + 1.5
    CLC
    LDA obj_world_pos+OBJ_WORLD_SHIP+2
    ADC #CAM_HEIGHT_LO
    STA cam_y_lo
    LDA obj_world_pos+OBJ_WORLD_SHIP+3
    ADC #CAM_HEIGHT_HI
    STA cam_y_hi

    RTS

; =====================================================================
; add_accel — Add signed 8-bit acceleration to 24-bit velocity
; =====================================================================
; Input:  A = signed acceleration value
;         X = velocity axis offset (0=X, 3=Y, 6=Z)
; Clobbers: A, Y

add_accel:
    TAY                      ; save for sign check
    CLC
    ADC vel_x_frac,X         ; add to frac byte
    STA vel_x_frac,X
    TYA                      ; N flag = sign of accel, carry preserved
    BPL @aa_pos
    ; Negative: sign-extend with $FF
    LDA #$FF
    ADC vel_x_lo,X
    STA vel_x_lo,X
    LDA #$FF
    ADC vel_x_hi,X
    STA vel_x_hi,X
    RTS
@aa_pos:
    ; Positive: sign-extend with $00
    LDA #$00
    ADC vel_x_lo,X
    STA vel_x_lo,X
    LDA #$00
    ADC vel_x_hi,X
    STA vel_x_hi,X
    RTS

; =====================================================================
; apply_drag — Subtract vel>>6 from 24-bit velocity
; =====================================================================
; Input:  X = velocity axis offset (0=X, 3=Y, 6=Z)
; Clobbers: A, $80-$82

apply_drag:
    ; drag_frac = (vel_lo << 2) | (vel_frac >> 6)
    LDA vel_x_frac,X
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                    ; vel_frac >> 6
    STA $80
    LDA vel_x_lo,X
    ASL A
    ASL A                    ; vel_lo << 2
    ORA $80
    STA $80                  ; drag_frac

    ; drag_lo = (vel_hi << 2) | (vel_lo >> 6)
    LDA vel_x_lo,X
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                    ; vel_lo >> 6
    STA $81
    LDA vel_x_hi,X
    ASL A
    ASL A                    ; vel_hi << 2
    ORA $81
    STA $81                  ; drag_lo

    ; drag_hi = sign of vel_hi (correct for |vel_hi| < 64)
    LDA vel_x_hi,X
    BPL @ad_pos
    LDA #$FF
    BRA @ad_sub
@ad_pos:
    LDA #$00
@ad_sub:
    STA $82                  ; drag_hi

    ; vel -= drag (24-bit)
    LDA vel_x_frac,X
    SEC
    SBC $80
    STA vel_x_frac,X
    LDA vel_x_lo,X
    SBC $81
    STA vel_x_lo,X
    LDA vel_x_hi,X
    SBC $82
    STA vel_x_hi,X
    RTS

; =====================================================================
; Included modules
; =====================================================================

.include "video.s"
.include "raster.s"
.include "math.s"
.include "grid.s"
.include "object.s"
.include "clip.s"
.include "map.s"
.include "status.s"
.include "tables.inc"
.include "map_data.inc"
.include "status_data.inc"
.include "interp_data.inc"
