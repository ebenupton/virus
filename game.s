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
.include "particle_zp.inc"

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
MAX_POS_Y_HI    = $28        ; max ship altitude in new scale ($2800 = 1.25 units)
MAX_POS_Y_LO    = $00

; Physics constants (16-bit velocity, 1/8192 world/frame² per unit)
GRAVITY_ACCEL   = 7           ; ~0.5 cells/s²
THRUST_ACCEL    = 21          ; 3× gravity
EXHAUST_SPEED   = 14          ; particle exhaust velocity scale

; === Game internal workspace (ZP_GAME internal) ===
ship_yaw        = ZP_GAME + 8      ; Y-axis rotation angle
ship_roll       = ZP_GAME + 9      ; X-axis roll angle

; Velocity: 16-bit signed (hi:lo) per axis, stride 2 for X-indexed access
vel_x_hi        = ZP_GAME + 10
vel_x_lo        = ZP_GAME + 11
vel_y_hi        = ZP_GAME + 12
vel_y_lo        = ZP_GAME + 13
vel_z_hi        = ZP_GAME + 14
vel_z_lo        = ZP_GAME + 15

; Ship position: 16-bit (lo:hi) per axis, new scale (256 hi = 8 world units)
; Y-indexed stride 2; convert_axis writes old-scale to obj_world_pos for rendering
ship_x_lo       = ZP_GAME + 16
ship_x_hi       = ZP_GAME + 17
ship_y_lo       = ZP_GAME + 18
ship_y_hi       = ZP_GAME + 19
ship_z_lo       = ZP_GAME + 20
ship_z_hi       = ZP_GAME + 21
enemy_rot       = ZP_GAME + 22     ; enemy Y-axis rotation (increments each frame)

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
    ; Initialize rotation angle and orientation
    LDA #0
    STA obj_rot_angle
    STA ship_yaw
    STA ship_roll
    STA enemy_rot

    ; Initialize velocities to zero (6 bytes)
    LDX #(vel_z_lo - vel_x_hi)
@clr_vel:
    STA vel_x_hi,X
    DEX
    BPL @clr_vel

    ; Initialize ship position in new scale
    ; X=4.0 → $8000, Y=31/32 → $1F00, Z=4.0 → $8000
    STA ship_x_lo           ; A=0
    STA ship_y_lo
    STA ship_z_lo
    LDA #$80
    STA ship_x_hi
    STA ship_z_hi
    LDA #$1F
    STA ship_y_hi

    JSR init_particles

    ; Initialize camera: follow ship at (4, 0, 4)
    LDA #0
    STA cam_x_lo
    LDA #$04
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
    JSR clear_particles
    JSR draw_grid

    ; Draw ship
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
    ; Merge ship dirty into grid dirty
    LDA obj_bb_min_sy
    CMP grid_min_sy
    BCS :+
    STA grid_min_sy
:
    ; Draw enemy (spins on axis: 256/64 = 4 per frame)
    LDA enemy_rot
    CLC
    ADC #4
    STA enemy_rot
    STA obj_rot_angle
    LDA #0
    STA obj_roll_angle
    LDA #<obj_enemy
    STA obj_ptr
    LDA #>obj_enemy
    STA obj_ptr+1
    LDY #OBJ_WORLD_ENEMY
    JSR setup_obj_view
    BCS @skip_enemy
    JSR draw_object
@skip_enemy:
    ; Merge enemy dirty into grid dirty
    LDA obj_bb_min_sy
    CMP grid_min_sy
    BCS :+
    STA grid_min_sy
:

    JSR update_particles
    JSR draw_particles

    ; Dirty top for this buffer (covers grid + objects; particles self-clear)
    LDA grid_min_sy
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
    JSR scan_key_add

    ; Clamp pitch to ±90° (valid: 0..64 and 192..255)
    LDA ship_roll
    CMP #65
    BCC @roll_ok
    CMP #192
    BCS @roll_ok
    CMP #128
    BCC @clamp_pos
    LDA #192                ; negative side (128..191) → clamp to -90°
    BNE @store_roll
@clamp_pos:
    LDA #64                 ; positive side (65..127) → clamp to +90°
@store_roll:
    STA ship_roll
@roll_ok:
    RTS

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

; zero_y_vel — Zero Y velocity (for ground/ceiling clamp)
zero_y_vel:
    LDA #0
    STA vel_y_hi
    STA vel_y_lo
    RTS

; =====================================================================
; Update physics — gravity, thrust, drag, position, ground clamp, camera
; =====================================================================

update_physics:
    ; 1. Gravity (always — subtract from Y velocity)
    LDA #<(-GRAVITY_ACCEL)
    LDX #2                   ; Y axis (stride 2)
    JSR add_accel

    ; 2. Thrust (if L key pressed)
    LDA #KEY_L
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @do_thrust
    JMP @no_thrust
@do_thrust:

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
    LDX #2                   ; Y axis
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
    LDX #4                   ; Z axis
    JSR add_accel

    ; ── Emit exhaust particle (opposite thrust direction) ──
    LDA particle_count
    CMP #MAX_PARTICLES
    BCC @emit_ok
    JMP @no_thrust
@emit_ok:

    LDX particle_count
    STX ptl_draw_count          ; save particle index (ptl_draw_count free)

    ; Position = ship world position
    LDA obj_world_pos + OBJ_WORLD_SHIP + 0
    STA ptl_x_lo,X
    LDA obj_world_pos + OBJ_WORLD_SHIP + 1
    STA ptl_x_hi,X
    LDA obj_world_pos + OBJ_WORLD_SHIP + 2
    STA ptl_y_lo,X
    LDA obj_world_pos + OBJ_WORLD_SHIP + 3
    STA ptl_y_hi,X
    LDA obj_world_pos + OBJ_WORLD_SHIP + 4
    STA ptl_z_lo,X
    LDA obj_world_pos + OBJ_WORLD_SHIP + 5
    STA ptl_z_hi,X

    ; Timer
    LDA #8
    STA ptl_timer,X

    ; Exhaust vy = -(cos(roll) * EXHAUST_SPEED) >> 7
    LDA #EXHAUST_SPEED
    STA math_b
    LDA gm_scratch_0           ; cos(roll), preserved across add_accel
    JSR smul_shr7
    EOR #$FF
    CLC
    ADC #1                      ; negate
    LDX ptl_draw_count
    STA ptl_vy,X

    ; horiz_neg = -(sin(roll) * EXHAUST_SPEED) >> 7
    LDA #EXHAUST_SPEED
    STA math_b
    LDA gm_scratch_1           ; sin(roll)
    JSR smul_shr7
    EOR #$FF
    CLC
    ADC #1
    STA gm_scratch_4           ; save horiz_neg

    ; Exhaust vx = (sin(yaw) * horiz_neg) >> 7
    STA math_b
    LDA gm_scratch_3           ; sin(yaw)
    JSR smul_shr7
    LDX ptl_draw_count
    STA ptl_vx,X

    ; Exhaust vz = (cos(yaw) * horiz_neg) >> 7
    LDA gm_scratch_4
    STA math_b
    LDA gm_scratch_2           ; cos(yaw)
    JSR smul_shr7
    LDX ptl_draw_count
    STA ptl_vz,X

    ; Random variation ([-2, +1] on each axis)
    ; random_byte preserves X, Y
    JSR random_byte
    AND #3
    SEC
    SBC #2
    CLC
    ADC ptl_vx,X
    STA ptl_vx,X

    JSR random_byte
    AND #3
    SEC
    SBC #2
    CLC
    ADC ptl_vy,X
    STA ptl_vy,X

    JSR random_byte
    AND #3
    SEC
    SBC #2
    CLC
    ADC ptl_vz,X
    STA ptl_vz,X

    ; Add ship velocity (convert new-scale vel to old-scale: (hi<<3)|(lo>>5))
    ; X axis
    LDA vel_x_lo
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    STA gm_scratch_0
    LDA vel_x_hi
    ASL A
    ASL A
    ASL A
    ORA gm_scratch_0
    CLC
    ADC ptl_vx,X
    STA ptl_vx,X

    ; Y axis
    LDA vel_y_lo
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    STA gm_scratch_0
    LDA vel_y_hi
    ASL A
    ASL A
    ASL A
    ORA gm_scratch_0
    CLC
    ADC ptl_vy,X
    STA ptl_vy,X

    ; Z axis
    LDA vel_z_lo
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    STA gm_scratch_0
    LDA vel_z_hi
    ASL A
    ASL A
    ASL A
    ORA gm_scratch_0
    CLC
    ADC ptl_vz,X
    STA ptl_vz,X

    INC particle_count

@no_thrust:
    ; 3. Drag (all 3 axes)
    LDX #0
    JSR apply_drag
    LDX #2
    JSR apply_drag
    LDX #4
    JSR apply_drag

    ; 4. Position update (16-bit add per axis, X=vel offset, Y=pos offset)
    LDX #0
    LDY #0
@pos_loop:
    JSR update_pos
    INX
    INX
    INY
    INY
    CPX #6
    BCC @pos_loop

    ; 5. Ground clamp: ship_y < 0 → clamp to 0
    LDA ship_y_hi
    BPL @above_ground
    LDA #0
    STA ship_y_lo
    STA ship_y_hi
@above_ground:

    ; 5b. Ceiling clamp: cap ship_y at MAX_POS_Y ($2800)
    LDA ship_y_hi
    CMP #MAX_POS_Y_HI
    BCC @below_ceiling
    LDA #MAX_POS_Y_LO
    STA ship_y_lo
    LDA #MAX_POS_Y_HI
    STA ship_y_hi
    JSR zero_y_vel
@below_ceiling:

    ; 5c. Convert new-scale ZP position to old-scale obj_world_pos
    LDY #0
@conv:
    JSR convert_axis
    INY
    INY
    CPY #6
    BCC @conv

    ; 6. Camera follow (reads old-scale obj_world_pos)
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
; update_pos — Add velocity to position for one axis (16-bit ZP)
; =====================================================================
; Input:  X = velocity offset (0=X, 2=Y, 4=Z)
;         Y = position offset (0=X, 2=Y, 4=Z)
; Preserves: X, Y

update_pos:
    CLC
    LDA ship_x_lo,Y
    ADC vel_x_lo,X
    STA ship_x_lo,Y
    LDA ship_x_hi,Y
    ADC vel_x_hi,X
    STA ship_x_hi,Y
    RTS

; =====================================================================
; add_accel — Add signed 8-bit acceleration to 16-bit velocity
; =====================================================================
; Input:  A = signed acceleration value
;         X = velocity axis offset (0=X, 2=Y, 4=Z)
; Clobbers: A, Y

add_accel:
    TAY                      ; save for sign check
    CLC
    ADC vel_x_lo,X           ; add to lo byte
    STA vel_x_lo,X
    TYA                      ; N flag = sign of accel, carry preserved
    BPL @aa_pos
    ; Negative: carry=1 → no borrow; carry=0 → borrow from hi
    BCS @aa_done
    DEC vel_x_hi,X
    RTS
@aa_pos:
    ; Positive: carry=0 → no overflow; carry=1 → carry into hi
    BCC @aa_done
    INC vel_x_hi,X
@aa_done:
    RTS

; =====================================================================
; apply_drag — Subtract vel>>6 from 16-bit velocity
; =====================================================================
; Input:  X = velocity axis offset (0=X, 2=Y, 4=Z)
; Clobbers: A, Y, gm_scratch_0-1

apply_drag:
    ; drag_lo = (vel_hi << 2) | (vel_lo >> 6)
    LDA vel_x_lo,X
    ASL A
    ROL A
    ROL A
    AND #$03                 ; vel_lo >> 6
    STA gm_scratch_0
    LDA vel_x_hi,X
    TAY                      ; cache vel_hi in Y
    ASL A
    ASL A                    ; vel_hi << 2
    ORA gm_scratch_0
    STA gm_scratch_0         ; drag_lo

    ; drag_hi = sign extend vel_hi
    LDA #0
    STA gm_scratch_1
    TYA
    BPL @ad_sub
    DEC gm_scratch_1         ; negative: drag_hi = $FF
@ad_sub:

    ; vel -= drag (16-bit)
    LDA vel_x_lo,X
    SEC
    SBC gm_scratch_0
    STA vel_x_lo,X
    TYA                      ; restore vel_hi from cache
    SBC gm_scratch_1
    STA vel_x_hi,X
    RTS

; =====================================================================
; convert_axis — Convert new-scale ZP position to old-scale obj_world_pos
; =====================================================================
; Input:  Y = axis offset (0=X, 2=Y, 4=Z)
; Output: obj_world_pos+OBJ_WORLD_SHIP lo/hi written
; Clobbers: A, gm_scratch_0

convert_axis:
    ; old_lo = (new_hi << 3) | (new_lo >> 5)
    ; old_hi = new_hi >> 5
    LDA ship_x_lo,Y
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                    ; new_lo >> 5
    STA gm_scratch_0
    LDA ship_x_hi,Y
    PHA
    ASL A
    ASL A
    ASL A                    ; new_hi << 3
    ORA gm_scratch_0
    STA obj_world_pos+OBJ_WORLD_SHIP,Y
    PLA
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                    ; new_hi >> 5
    STA obj_world_pos+OBJ_WORLD_SHIP+1,Y
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
.include "particle.s"
.include "map.s"
.include "status.s"
.include "tables.inc"
.include "map_data.inc"
.include "status_data.inc"
.include "interp_data.inc"
