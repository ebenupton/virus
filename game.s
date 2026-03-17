; game.s — Real-time perspective grid with camera translation for BBC Micro
; Assembled with ca65: ca65 game.s -o game.o
; Linked with ld65:    ld65 -C linker.cfg game.o -o game.bin
;
; Loads and runs at $0600. Double-buffered at $3000/$5800 (10K each).
; MODE 2-like video: 128×160, 4bpp, 512-byte stripes.
; XOR rendering for flicker-free erase/redraw.
;
; Parameterisable grid centred on camera tile, projected in real time each frame.
; Height modulation from 32×32 toroidal heightmap (5-bit height, 3-bit colour).

; CPU selection: default NMOS 6502; pass -DCPU_65C02=1 for 65C02 optimisations
.ifdef CPU_65C02
    .setcpu "65C02"
.else
    .setcpu "6502"
.endif
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
.include "zp_layout.inc"
.include "video_zp.inc"
.include "game_zp.inc"
.include "raster_zp.inc"
.include "math_zp.inc"
.include "grid_zp.inc"
.include "object_zp.inc"

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
MAX_POS_Y_HI    = $01        ; max ship altitude = 1.25 units
MAX_POS_Y_LO    = $40

; Physics constants (12.5 fps, 1 grid cell = $40 in 8.8)
GRAVITY_ACCEL   = 52          ; 0.5 cells/s²
THRUST_ACCEL    = 104         ; 2× gravity

; === Game internal workspace (ZP_GAME internal) ===
ship_yaw        = ZP_GAME + 8      ; Y-axis rotation angle
ship_roll       = ZP_GAME + 9      ; X-axis roll angle

; Velocity: 24-bit signed (hi:lo:frac) per axis (contiguous for loop zeroing)
vel_x_hi        = ZP_GAME + 10
vel_x_lo        = ZP_GAME + 11
vel_x_frac      = ZP_GAME + 12
vel_y_hi        = ZP_GAME + 13
vel_y_lo        = ZP_GAME + 14
vel_y_frac      = ZP_GAME + 15
vel_z_hi        = ZP_GAME + 16
vel_z_lo        = ZP_GAME + 17
vel_z_frac      = ZP_GAME + 18

; Sub-pixel position accumulators (stride-2 for Y-indexed update_pos)
pos_x_frac      = ZP_GAME + 19
pos_y_frac      = ZP_GAME + 21
pos_z_frac      = ZP_GAME + 23

; Game scratch (ZP_SHARED spares, used only during thrust/drag)
gm_scratch_0    = ZP_SHARED + 1
gm_scratch_1    = ZP_SHARED + 2
gm_scratch_2    = ZP_SHARED + 3
gm_scratch_3    = ZP_SHARED + 4
gm_scratch_4    = ZP_SHARED + 5

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
    JSR set_page
    JSR draw_map              ; blit minimap to buf0
    LDA #$58
    JSR set_page              ; restore to buf1 (back buffer)

    ; Mark both buffers clean so first clear_screen doesn't erase the map
    LDA #160
    STA dirty_top_buf0
    STA dirty_top_buf1
    ; No ship drawn yet
    LDA #20
    STA ship_top_buf0
    STA ship_top_buf1
    STA ship_bot_buf0
    STA ship_bot_buf1

    ; Initialize rotation angle and orientation
    LDA #0
    STA obj_rot_angle
    STA ship_yaw
    STA ship_roll

    ; Initialize velocities to zero (vel_x_hi..$2E contiguous)
    LDX #(vel_z_frac - vel_x_hi)
@clr_vel:
    STA vel_x_hi,X
    DEX
    BPL @clr_vel

    ; Initialize position fraction accumulators
    STA pos_x_frac
    STA pos_y_frac
    STA pos_z_frac

    ; Initialize camera: follow ship at (4, 0, 4)
    STA cam_x_lo
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
    JSR clear_ship
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

    ; Grid-only dirty top for this buffer
    LDA grid_min_sy
    LDX back_buf_idx
    STA dirty_top_buf0,X

    ; Ship stripe range for this buffer's clear_ship
    LDA obj_bb_min_sy         ; 0-159 or 160 (no ship)
    LSR A
    LSR A
    LSR A                     ; stripe 0-19 or 20 (none)
    STA ship_top_buf0,X
    LDA obj_bb_max_sy
    LSR A
    LSR A
    LSR A
    STA ship_bot_buf0,X

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

    LDA #KEY_Z              ; Z key → yaw right (ship_yaw -= 4)
    LDX #ship_yaw
    LDY #<(-4)
    JSR scan_key_add
    LDA #KEY_X              ; X key → yaw left (ship_yaw += 4)
    LDY #4
    JSR scan_key_add
    LDA #KEY_K              ; K key → roll left (ship_roll += 4)
    LDX #ship_roll
    JSR scan_key_add
    LDA #KEY_M              ; M key → roll right (ship_roll -= 4)
    LDY #<(-4)
    JMP scan_key_add        ; tail call

; scan_key_add — Check key and add signed delta to ZP variable
; Input: A = key code, X = ZP address, Y = signed delta
; Preserves: X
scan_key_add:
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BPL @ska_done
    TYA
    CLC
    ADC $00,X
    STA $00,X
@ska_done:
    RTS

; zero_y_vel — Zero Y velocity and position fraction (for ground/ceiling clamp)
zero_y_vel:
    LDA #0
    STA pos_y_frac
    STA vel_y_hi
    STA vel_y_lo
    STA vel_y_frac
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
    BPL @no_thrust

    ; Precompute trig values into scratch
    LDX ship_roll
    JSR sincos
    STA gm_scratch_1          ; sin(roll)
    STX gm_scratch_0          ; cos(roll)
    LDX ship_yaw
    JSR sincos
    STA gm_scratch_3          ; sin(yaw)
    STX gm_scratch_2          ; cos(yaw)

    ; thrust_y = (cos(roll) * THRUST_ACCEL) >> 7
    LDA #THRUST_ACCEL
    STA math_b
    LDA gm_scratch_0
    JSR smul_shr7
    LDX #3                   ; Y axis
    JSR add_accel

    ; horiz = (sin(roll) * THRUST_ACCEL) >> 7
    LDA gm_scratch_1
    ; math_b still = THRUST_ACCEL from above
    JSR smul_shr7
    STA gm_scratch_4          ; save horiz

    ; thrust_x = (sin(yaw) * horiz) >> 7
    LDA gm_scratch_4
    STA math_b
    LDA gm_scratch_3
    JSR smul_shr7
    LDX #0                   ; X axis
    JSR add_accel

    ; thrust_z = (cos(yaw) * horiz) >> 7
    LDA gm_scratch_2
    ; math_b still = horiz from above
    JSR smul_shr7
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

    ; 4. Position update (24-bit add per axis, X=vel offset, Y=pos offset)
    LDX #0
    LDY #0
@pos_loop:
    JSR update_pos
    INX
    INX
    INX
    INY
    INY
    CPX #9
    BCC @pos_loop

    ; 5. Ground clamp: clamp y to zero (position only, keep velocity)
    LDA obj_world_pos+OBJ_WORLD_SHIP+3    ; y_hi
    BPL @above_ground                      ; >= 0 → above ground
    LDA #0
    STA obj_world_pos+OBJ_WORLD_SHIP+2
    STA obj_world_pos+OBJ_WORLD_SHIP+3
    STA pos_y_frac
@above_ground:

    ; 5b. Ceiling clamp: cap ship_y at MAX_POS_Y
    LDA obj_world_pos+OBJ_WORLD_SHIP+3    ; y_hi
    CMP #MAX_POS_Y_HI
    BCC @below_ceiling
    BNE @do_ceil_clamp
    LDA obj_world_pos+OBJ_WORLD_SHIP+2    ; y_lo
    CMP #MAX_POS_Y_LO
    BCC @below_ceiling
@do_ceil_clamp:
    LDA #MAX_POS_Y_LO
    STA obj_world_pos+OBJ_WORLD_SHIP+2
    LDA #MAX_POS_Y_HI
    STA obj_world_pos+OBJ_WORLD_SHIP+3
    JSR zero_y_vel
@below_ceiling:

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
; smul_shr7 — Signed multiply then shift right 7
; =====================================================================
; Input:  A = first arg, math_b set
; Output: A = (A * math_b) >> 7

smul_shr7:
    JSR smul8x8             ; A = math_res_hi
    ASL math_res_lo
    ROL A
    RTS

; =====================================================================
; sincos — Look up sin and cos of angle
; =====================================================================
; Input:  X = angle (0-255)
; Output: A = sin(angle), X = cos(angle)
; Clobbers: none besides A, X

sincos:
    LDA sin_table,X
    TAY                     ; Y = sin (3 cycles faster than PHA/PLA)
    TXA
    CLC
    ADC #64
    TAX
    LDA sin_table,X         ; cos
    TAX                     ; X = cos
    TYA                     ; A = sin
    RTS

; =====================================================================
; update_pos — Add velocity to position for one axis
; =====================================================================
; Input:  X = velocity offset (0=X, 3=Y, 6=Z)
;         Y = position offset (0=X, 2=Y, 4=Z)
; Preserves: X, Y

update_pos:
    CLC
    LDA pos_x_frac,Y
    ADC vel_x_frac,X
    STA pos_x_frac,Y
    LDA obj_world_pos+OBJ_WORLD_SHIP,Y
    ADC vel_x_lo,X
    STA obj_world_pos+OBJ_WORLD_SHIP,Y
    LDA obj_world_pos+OBJ_WORLD_SHIP+1,Y
    ADC vel_x_hi,X
    STA obj_world_pos+OBJ_WORLD_SHIP+1,Y
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
    ; Negative: carry=1 → no change to lo:hi; carry=0 → decrement
    BCS @aa_done
    LDA vel_x_lo,X
    BNE @aa_dec_lo
    DEC vel_x_hi,X
@aa_dec_lo:
    DEC vel_x_lo,X
    RTS
@aa_pos:
    ; Positive: carry=0 → no change to lo:hi; carry=1 → increment
    BCC @aa_done
    INC vel_x_lo,X
    BNE @aa_done
    INC vel_x_hi,X
@aa_done:
    RTS

; =====================================================================
; apply_drag — Subtract vel>>6 from 24-bit velocity
; =====================================================================
; Input:  X = velocity axis offset (0=X, 3=Y, 6=Z)
; Clobbers: A, gm_scratch_0-2

apply_drag:
    ; drag_frac = (vel_lo << 2) | (vel_frac >> 6)
    LDA vel_x_frac,X
    ASL A
    ROL A
    ROL A
    AND #$03                 ; vel_frac >> 6
    STA gm_scratch_0
    LDA vel_x_lo,X
    ASL A
    ASL A                    ; vel_lo << 2
    ORA gm_scratch_0
    STA gm_scratch_0         ; drag_frac

    ; drag_lo = (vel_hi << 2) | (vel_lo >> 6)
    LDA vel_x_lo,X
    ASL A
    ROL A
    ROL A
    AND #$03                 ; vel_lo >> 6
    STA gm_scratch_1
    LDA vel_x_hi,X
    TAY                      ; cache vel_hi in Y
    ASL A
    ASL A                    ; vel_hi << 2
    ORA gm_scratch_1
    STA gm_scratch_1         ; drag_lo

    ; drag_hi = sign of vel_hi (correct for |vel_hi| < 64)
    LDA #0
    STA gm_scratch_2         ; assume positive (drag_hi = 0)
    TYA                      ; restore vel_hi for sign check
    BPL @ad_sub
    DEC gm_scratch_2         ; negative: drag_hi = $FF
@ad_sub:

    ; vel -= drag (24-bit)
    LDA vel_x_frac,X
    SEC
    SBC gm_scratch_0
    STA vel_x_frac,X
    LDA vel_x_lo,X
    SBC gm_scratch_1
    STA vel_x_lo,X
    TYA                      ; restore vel_hi from cache
    SBC gm_scratch_2
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
