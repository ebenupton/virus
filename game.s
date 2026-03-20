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
MAX_POS_Y_HI    = $50        ; max ship altitude in new scale ($5000 = 2.5 units)
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
; Y-indexed stride 2; convert_axis writes old-scale to ship_pos for rendering
ship_x_lo       = ZP_GAME + 16
ship_x_hi       = ZP_GAME + 17
ship_y_lo       = ZP_GAME + 18
ship_y_hi       = ZP_GAME + 19
ship_z_lo       = ZP_GAME + 20
ship_z_hi       = ZP_GAME + 21
enemy_rot       = ZP_GAME + 22     ; enemy Y-axis rotation (increments each frame)
ship_state      = ZP_GAME + 6      ; 0=alive, 1=dead, 2=ready
debris_count    = ZP_GAME + 7      ; active debris pieces (0..4)
STATE_ALIVE     = 0
STATE_DEAD      = 1
STATE_READY     = 2

; Enemy state (3 dynamic enemies, free ZP $D8+)
NUM_ENEMIES = 3
enemy_x_lo  = $D8
enemy_x_hi  = $DB
enemy_z_lo  = $DE
enemy_z_hi  = $E1
enemy_vx    = $E4
enemy_vz    = $E7
enemy_yaw   = $EA
enemy_idx   = $ED

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
    ; (status rows zeroed by init_status below, no separate clear needed)
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
    STA ship_state
    STA debris_count
    STA particle_count
    STA ptl_clr_count
    STA ptl_clr_count+1
    STA cam_x_lo
    JSR reset_ship_pos        ; zeros velocities, sets position
    LDA #$42
    STA particle_rng_lo
    LDA #$7E
    STA particle_rng_hi
    JSR init_enemies

    ; Initialize camera: follow ship at (4, 0, 4)
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

    ; Draw ship or debris
    LDA ship_state
    BNE @draw_debris

    ; --- Ship alive ---
    LDA ship_yaw
    STA obj_rot_angle
    LDA ship_roll
    STA obj_roll_angle
    LDA #<obj_ship
    STA obj_ptr
    LDA #>obj_ship
    STA obj_ptr+1
    LDX #5
:   LDA ship_pos,X
    STA obj_pos,X
    DEX
    BPL :-
    JSR setup_obj_view
    BCS @ship_drawn
    JSR draw_object
@ship_drawn:
    JMP @merge_dirty

@draw_debris:
    LDX debris_count
    DEX
    BMI @merge_dirty          ; no debris left (dead or ready)
@debris_loop:
    STX gm_scratch_0
    ; Copy debris pos to enemy slot (not ship — draw_grid reads ship slot)
    LDA debris_x_lo,X
    STA obj_pos + 0
    LDA debris_x_hi,X
    STA obj_pos + 1
    LDA debris_y_lo,X
    STA obj_pos + 2
    LDA debris_y_hi,X
    STA obj_pos + 3
    LDA debris_z_lo,X
    STA obj_pos + 4
    LDA debris_z_hi,X
    STA obj_pos + 5
    ; Rotation + tumble
    LDA debris_rot,X
    STA obj_rot_angle
    LDA debris_roll,X
    STA obj_roll_angle
    ; Object type
    LDA #<obj_debris
    STA obj_ptr
    LDA #>obj_debris
    STA obj_ptr+1
    ; Draw
    JSR setup_obj_view
    BCS @skip_debris
    JSR draw_object
@skip_debris:
    ; Merge this debris dirty
    LDA obj_bb_min_sy
    CMP grid_min_sy
    BCS :+
    STA grid_min_sy
:
    LDX gm_scratch_0
    DEX
    BPL @debris_loop

@merge_dirty:
    ; Merge ship/debris dirty into grid dirty
    LDA obj_bb_min_sy
    CMP grid_min_sy
    BCS :+
    STA grid_min_sy
:
    ; Draw enemies — set up invariants outside loop
    JSR update_enemies
    LDA #<obj_enemy
    STA obj_ptr
    LDA #>obj_enemy
    STA obj_ptr+1
    LDA #0
    STA obj_roll_angle
    LDX #NUM_ENEMIES-1
@enemy_loop:
    STX enemy_idx

    ; Compute bilinear terrain height at enemy position
    LDA enemy_x_hi,X
    STA gm_scratch_2
    LDA enemy_z_hi,X
    STA gm_scratch_3
    LDA enemy_x_lo,X
    STA gm_scratch_4
    LDA enemy_z_lo,X          ; A = z_lo (input to bilinear_height)
    JSR bilinear_height        ; A = interpolated h*8

    ; enemy Y = h*8 + $80 (terrain + 0.5 world units)
    LDX enemy_idx
    CLC
    ADC #$80
    STA obj_pos+2              ; y_lo
    LDA #0
    ADC #0
    STA obj_pos+3              ; y_hi (0 or 1)

    ; Copy X and Z to obj_pos
    LDA enemy_x_lo,X
    STA obj_pos+0
    LDA enemy_x_hi,X
    STA obj_pos+1
    LDA enemy_z_lo,X
    STA obj_pos+4
    LDA enemy_z_hi,X
    STA obj_pos+5

    ; Rotation
    LDA enemy_yaw,X
    STA obj_rot_angle

    ; Draw
    JSR setup_obj_view
    BCS @skip_enemy
    JSR draw_object
@skip_enemy:
    ; Merge dirty
    LDA obj_bb_min_sy
    CMP grid_min_sy
    BCS :+
    STA grid_min_sy
:
    LDX enemy_idx
    DEX
    BPL @enemy_loop

    JSR update_particles
    JSR draw_particles

    ; Dirty top for this buffer (covers grid + objects; particles self-clear)
    LDA grid_min_sy
    LDX back_buf_idx
    STA dirty_top_buf0,X

.ifdef EMU_DEBUG
    ; Frame timing: show vsync delta as score's last digit
    LDA $FE34
    TAX                       ; save current
    SEC
    SBC dbg_last_vsync
    STX dbg_last_vsync
    CMP #10
    BCC :+
    LDA #9
:   STA score+3               ; overwrite entire byte (hi nibble irrelevant)
.endif

    JSR draw_status
    JSR wait_vsync
    JSR flip_buffers
    JMP main_loop

; =====================================================================
; Update camera — VIA key scanning, direct X/Z translation
; =====================================================================

update_camera:
    LDA #$7F
    STA SYS_VIA_DDRA        ; bits 0-6 output, bit 7 input (always, for space check)
    LDA ship_state
    BNE @roll_ok              ; skip input when not alive

    LDA #KEY_Z              ; Z key → yaw right (ship_yaw -= 4)
    LDX #ship_yaw
    LDY #<(-4)
    JSR scan_key_add
    LDA #KEY_X              ; X key → yaw left (ship_yaw += 4)
    LDY #4
    JSR scan_key_add
    ; Skip roll input when landed (roll==0 and vel_y_hi==0)
    LDA ship_roll
    ORA vel_y_hi
    ORA vel_y_lo
    BEQ @roll_ok              ; landed → skip roll input + clamp (roll already 0)
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

; =====================================================================
; random_adj — Random value in [-2, +1], carry clear for subsequent ADC
; =====================================================================
; Output: A = random[-2..+1], C=0
; Preserves: X, Y

random_adj:
    JSR random_byte
    AND #3
    SEC
    SBC #2
    CLC
    RTS

; =====================================================================
; vel_to_old_scale — Convert 16-bit new-scale velocity to 8-bit old-scale
; =====================================================================
; Input:  Y = axis offset (0=X, 2=Y, 4=Z) into vel_x_hi/vel_x_lo
; Output: A = (vel_hi << 3) | (vel_lo >> 5)
; Preserves: X

vel_to_old_scale:
    LDA vel_x_lo,Y
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    STA gm_scratch_0
    LDA vel_x_hi,Y
    ASL A
    ASL A
    ASL A
    ORA gm_scratch_0
    RTS

.ifdef EMU_DEBUG
dbg_last_vsync: .byte 0
.endif

; ── Persistent object positions (8.8 fixed-point, 6 bytes each) ──────
ship_pos:     .res 6              ; ship old-scale position (written by convert loop)

; (enemy state arrays in ZP, defined at top of file)

; ── Debris state (ship destruction) ──────────────────────────────────
debris_x_lo:  .res 4
debris_x_hi:  .res 4
debris_y_lo:  .res 4
debris_y_hi:  .res 4
debris_z_lo:  .res 4
debris_z_hi:  .res 4
debris_vx:    .res 4
debris_vy:    .res 4
debris_vz:    .res 4
debris_rot:   .res 4
debris_roll:  .res 4

; =====================================================================
; Update physics — gravity, thrust, drag, position, ground clamp, camera
; =====================================================================

update_physics:
    LDA ship_state
    BEQ @phys_alive
    CMP #STATE_READY
    BEQ @phys_ready
    ; --- Dead: update debris, check for dead→ready ---
    JSR update_debris
    LDA debris_count
    BNE @phys_done            ; still debris → stay dead
    ; All debris gone — transition if space NOT pressed
    LDA #KEY_SPACE
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @phys_done            ; space held → wait
    LDA #STATE_READY
    STA ship_state
@phys_done:
    RTS
@phys_ready:
    ; --- Ready: wait for space → respawn ---
    LDA #KEY_SPACE
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BPL @phys_done            ; space not pressed → wait
    JMP respawn_ship          ; tail call
@phys_alive:
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
    LDA ship_pos +0
    STA ptl_x_lo,X
    LDA ship_pos +1
    STA ptl_x_hi,X
    LDA ship_pos +2
    STA ptl_y_lo,X
    LDA ship_pos +3
    STA ptl_y_hi,X
    LDA ship_pos +4
    STA ptl_z_lo,X
    LDA ship_pos +5
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
    ; math_b still = EXHAUST_SPEED from above
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
    JSR random_adj
    ADC ptl_vx,X
    STA ptl_vx,X
    JSR random_adj
    ADC ptl_vy,X
    STA ptl_vy,X
    JSR random_adj
    ADC ptl_vz,X
    STA ptl_vz,X

    ; Add ship velocity (convert new-scale vel to old-scale: (hi<<3)|(lo>>5))
    LDY #0
    JSR vel_to_old_scale
    CLC
    ADC ptl_vx,X
    STA ptl_vx,X

    LDY #2
    JSR vel_to_old_scale
    CLC
    ADC ptl_vy,X
    STA ptl_vy,X

    LDY #4
    JSR vel_to_old_scale
    CLC
    ADC ptl_vz,X
    STA ptl_vz,X

    INC particle_count

@no_thrust:
    ; 3. Drag (all 3 axes, reverse order — independent)
    LDX #4
@drag_loop:
    JSR apply_drag
    DEX
    DEX
    BPL @drag_loop

    ; 4. Position update (16-bit add per axis, all X-indexed)
    LDX #0
@pos_loop:
    CLC
    LDA ship_x_lo,X
    ADC vel_x_lo,X
    STA ship_x_lo,X
    LDA ship_x_hi,X
    ADC vel_x_hi,X
    STA ship_x_hi,X
    INX
    INX
    CPX #6
    BCC @pos_loop

    ; 5. Ground clamp: ship_y < 0 → clamp to 0
    LDA ship_y_hi
    BPL @above_ground
    LDA #0
    STA ship_y_lo
    STA ship_y_hi
    BEQ @below_ceiling        ; A=0 from LDA, always taken
@above_ground:

    ; 5b. Ceiling clamp: cap ship_y at MAX_POS_Y ($2800)
    ; A = ship_y_hi (from initial LDA, no reload needed)
    CMP #MAX_POS_Y_HI
    BCC @below_ceiling
    LDA #0                    ; = MAX_POS_Y_LO
    STA ship_y_lo
    STA vel_y_hi              ; inlined zero_y_vel
    STA vel_y_lo
    LDA #MAX_POS_Y_HI
    STA ship_y_hi
@below_ceiling:

    ; 5c. Convert new-scale ZP position to old-scale ship_pos
    LDX #0
@conv:
    LDA ship_x_lo,X
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                    ; new_lo >> 5
    STA gm_scratch_0
    LDA ship_x_hi,X
    PHA
    ASL A
    ASL A
    ASL A                    ; new_hi << 3
    ORA gm_scratch_0
    STA ship_pos,X
    PLA
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                    ; new_hi >> 5
    STA ship_pos+1,X
    INX
    INX
    CPX #6
    BCC @conv

    ; 5d. Terrain collision
    JSR check_terrain

    ; 6. Camera follow (reads old-scale ship_pos)
    LDA ship_pos+0
    STA cam_x_lo
    LDA ship_pos+1
    STA cam_x_hi
    ; cam_z = ship_z - CAM_Z_BEHIND
    LDA ship_pos+4
    SEC
    SBC #<CAM_Z_BEHIND
    STA cam_z_lo
    LDA ship_pos+5
    SBC #>CAM_Z_BEHIND
    STA cam_z_hi

    ; 7. Camera Y = ship_y + 1.5
    CLC
    LDA ship_pos+2
    ADC #CAM_HEIGHT_LO
    STA cam_y_lo
    LDA ship_pos+3
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
    TXA
    CLC
    ADC #64
    TAY                     ; Y = cos index
    LDA sin_table,X         ; A = sin(angle)
    LDX sin_table,Y         ; X = cos(angle)
    RTS

; (update_pos inlined into position loop)

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

    ; vel -= drag (16-bit); drag_hi = 0 (vel>=0) or $FF (vel<0)
    LDA vel_x_lo,X
    SEC
    SBC gm_scratch_0
    STA vel_x_lo,X
    TYA                      ; A = vel_hi (carry preserved)
    BPL @ad_pos
    SBC #$FF                 ; negative: A = vel_hi - $FF - borrow = vel_hi + C
    .byte $2C                ; BIT abs — skip next 2 bytes (SBC #0)
@ad_pos:
    SBC #0                   ; positive: A = vel_hi - 0 - borrow
    STA vel_x_hi,X
    RTS

; (convert_axis inlined into conversion loop)

; =====================================================================
; check_terrain — Test ship against heightmap, handle landing/crash
; =====================================================================

check_terrain:
    ; Compute heightmap col from new-scale ship_x: (ship_x_hi >> 3) & $1F
    LDA ship_x_hi
    LSR A
    LSR A
    LSR A
    AND #$1F
    TAY                       ; Y = col

    ; Compute heightmap row from new-scale ship_z: (ship_z_hi >> 3) & $1F
    LDA ship_z_hi
    LSR A
    LSR A
    LSR A
    AND #$1F

    ; Build pointer: height_map + row * 32
    LDX #>height_map / 4
    STX gm_scratch_1
    ASL A
    ASL A
    ASL A
    ASL A
    ROL gm_scratch_1
    ASL A
    ROL gm_scratch_1
    STA gm_scratch_0

    ; Read cell
    LDA (gm_scratch_0),Y     ; cell byte
    STA gm_scratch_2          ; save full cell
    AND #$F8                  ; h*8
    LSR A
    LSR A
    LSR A                     ; h_raw (0..31) = terrain height in new-scale hi

    ; Compare: ship_y_hi vs h_raw
    CMP ship_y_hi
    BCC @ct_done              ; h_raw < ship_y_hi → ship above terrain

    ; Ship below terrain — check for plateau landing
    STA gm_scratch_3          ; save h_raw

    LDA gm_scratch_2          ; cell byte
    AND #$F8
    CMP #$F8                  ; plateau?
    BNE @ct_crash

    ; Over plateau — check flat pitch
    LDA ship_roll
    CMP #8
    BCC @ct_land              ; 0..7 → nearly flat
    CMP #249
    BCS @ct_land              ; 249..255 → nearly flat

@ct_crash:
    JMP destroy_ship          ; tail call

@ct_land:
    ; Clamp Y to terrain, flat pitch; zero y_lo + vel only if descending
    LDA gm_scratch_3
    STA ship_y_hi
    LDA #0
    STA ship_roll
    LDX vel_y_hi              ; test sign (preserves A=0)
    BPL @ct_conv              ; vel_y >= 0 → keep y_lo + vel (allow takeoff)
    STA ship_y_lo             ; A=0: clamp fractional to surface
    STA vel_y_hi
    STA vel_y_lo
@ct_conv:
@ct_done:
    RTS

; =====================================================================
; get_terrain_h8 — Look up terrain h*8 from old-scale position
; =====================================================================
; Input:  gm_scratch_2 = x_hi (old-scale), gm_scratch_3 = z_hi (old-scale)
; Output: A = h*8 (0..248)
; Preserves: X
; Clobbers: A, Y, gm_scratch_0, gm_scratch_1

get_terrain_h8:
    ; col = (x_hi << 2) & $1F → Y
    LDA gm_scratch_2
    ASL A
    ASL A
    AND #$1F
    TAY                       ; Y = col

    ; row = (z_hi << 2) & $1F → build pointer
    LDA #>height_map / 4
    STA gm_scratch_1
    LDA gm_scratch_3
    ASL A
    ASL A
    AND #$1F
    ASL A
    ASL A
    ASL A
    ASL A
    ROL gm_scratch_1
    ASL A
    ROL gm_scratch_1
    STA gm_scratch_0

    ; Read cell
    LDA (gm_scratch_0),Y
    AND #$F8                  ; h*8
    RTS

; =====================================================================
; destroy_ship — Set dead flag, spawn 3 debris pieces
; =====================================================================

destroy_ship:
    LDA #STATE_DEAD
    STA ship_state
    LDA #4
    STA debris_count

    ; Zero ship velocity
    LDA #0
    STA vel_y_hi
    STA vel_y_lo

    ; Init 4 debris pieces at ship's old-scale position
    LDX #3
@ds_loop:
    LDA ship_pos +0
    STA debris_x_lo,X
    LDA ship_pos +1
    STA debris_x_hi,X
    LDA ship_pos +2
    STA debris_y_lo,X
    LDA ship_pos +3
    STA debris_y_hi,X
    LDA ship_pos +4
    STA debris_z_lo,X
    LDA ship_pos +5
    STA debris_z_hi,X

    ; Random upward velocity (10..25)
    JSR random_byte
    AND #$0F
    CLC
    ADC #10
    STA debris_vy,X

    ; Random outward X velocity (-8..7)
    JSR random_byte
    AND #$0F
    SEC
    SBC #8
    STA debris_vx,X

    ; Random outward Z velocity (-8..7)
    JSR random_byte
    AND #$0F
    SEC
    SBC #8
    STA debris_vz,X

    ; Random initial rotation + roll (derive roll from rot)
    JSR random_byte
    STA debris_rot,X
    EOR #$A5
    STA debris_roll,X

    DEX
    BPL @ds_loop
    RTS

; =====================================================================
; respawn_ship — Reset ship to start position, transition to alive
; =====================================================================

respawn_ship:
    LDA #0
    STA ship_state
    STA ship_yaw
    STA ship_roll
    JSR init_enemies
    JMP reset_ship_pos        ; tail call

; =====================================================================
; reset_ship_pos — Zero velocities, set ship to start position
; =====================================================================
; Clobbers: A, X

reset_ship_pos:
    LDA #0
    LDX #(ship_z_hi - vel_x_hi)
:   STA vel_x_hi,X            ; clear vel (6 bytes) + ship pos (6 bytes)
    DEX
    BPL :-
    LDA #$80
    STA ship_x_hi
    STA ship_z_hi
    LDA #$1F
    STA ship_y_hi
    RTS

; =====================================================================
; update_debris — Physics for debris pieces (gravity + position + spin)
; =====================================================================

update_debris:
    LDX debris_count
    DEX                       ; X = count-1 (last index)
    BPL @ud_loop
    RTS                       ; no debris → return
@ud_loop:
    ; Gravity
    DEC debris_vy,X

    ; Y axis: sign-extend debris_vy and add to position
    LDA debris_vy,X
    CLC
    ADC debris_y_lo,X
    STA debris_y_lo,X
    LDY debris_vy,X
    BMI @ud_vy_neg
    BCC @ud_vy_done
    INC debris_y_hi,X
@ud_vy_done:

    ; X axis
    LDA debris_vx,X
    CLC
    ADC debris_x_lo,X
    STA debris_x_lo,X
    LDY debris_vx,X
    BMI @ud_vx_neg
    BCC @ud_vx_done
    INC debris_x_hi,X
@ud_vx_done:

    ; Z axis
    LDA debris_vz,X
    CLC
    ADC debris_z_lo,X
    STA debris_z_lo,X
    LDY debris_vz,X
    BMI @ud_vz_neg
    BCC @ud_vz_done
    INC debris_z_hi,X
@ud_vz_done:

    ; Spin + tumble
    LDA debris_rot,X
    CLC
    ADC #7
    STA debris_rot,X
    INC debris_roll,X         ; tumble (slower roll)

    ; GC: remove if at or below terrain height
    LDA debris_y_hi,X
    BMI @ud_gc                ; y < 0 → below any terrain
    BNE @ud_next              ; y_hi > 0 → above all terrain
    ; y_hi = 0: compare y_lo with terrain h*8
    LDA debris_x_hi,X
    STA gm_scratch_2
    LDA debris_z_hi,X
    STA gm_scratch_3
    JSR get_terrain_h8        ; A = h*8 (X preserved)
    CMP debris_y_lo,X         ; h*8 vs y_lo
    BCS @ud_gc                ; h*8 >= y_lo → at/below terrain

@ud_next:
    DEX
    BPL @ud_loop
    RTS

    ; Outlined negative velocity handlers (carry preserved from ADC)
@ud_vy_neg:
    LDA debris_y_hi,X
    ADC #$FF
    STA debris_y_hi,X
    JMP @ud_vy_done
@ud_vx_neg:
    LDA debris_x_hi,X
    ADC #$FF
    STA debris_x_hi,X
    JMP @ud_vx_done
@ud_vz_neg:
    LDA debris_z_hi,X
    ADC #$FF
    STA debris_z_hi,X
    JMP @ud_vz_done

@ud_gc:
    ; Swap-and-pop: copy last slot to this one, decrement count
    DEC debris_count
    LDY debris_count          ; Y = new count = last valid index
    BEQ @ud_done              ; count hit 0 → no pieces left
    ; Copy slot Y → slot X (11 arrays)
    LDA debris_x_lo,Y
    STA debris_x_lo,X
    LDA debris_x_hi,Y
    STA debris_x_hi,X
    LDA debris_y_lo,Y
    STA debris_y_lo,X
    LDA debris_y_hi,Y
    STA debris_y_hi,X
    LDA debris_z_lo,Y
    STA debris_z_lo,X
    LDA debris_z_hi,Y
    STA debris_z_hi,X
    LDA debris_vx,Y
    STA debris_vx,X
    LDA debris_vy,Y
    STA debris_vy,X
    LDA debris_vz,Y
    STA debris_vz,X
    LDA debris_rot,Y
    STA debris_rot,X
    LDA debris_roll,Y
    STA debris_roll,X
    JMP @ud_next              ; re-process this slot (now has swapped piece)
@ud_done:
    RTS

; =====================================================================
; init_enemies — Randomize position and velocity for all enemies
; =====================================================================

init_enemies:
    LDX #NUM_ENEMIES-1
@ie_loop:
    JSR random_byte
    STA enemy_x_lo,X
    STA enemy_z_hi,X          ; reuse for z_hi
    JSR random_byte
    STA enemy_x_hi,X
    STA enemy_z_lo,X          ; reuse for z_lo
    JSR random_byte
    STA enemy_yaw,X
    AND #$07
    SEC
    SBC #3
    STA enemy_vx,X
    EOR #$A5
    AND #$07
    SEC
    SBC #3
    STA enemy_vz,X
    DEX
    BPL @ie_loop
    RTS

; =====================================================================
; update_enemies — Move enemies along their velocity vectors
; =====================================================================

update_enemies:
    LDX #NUM_ENEMIES-1
@ue_loop:
    ; X movement: sign-extend vel and add to 16-bit pos
    LDA enemy_vx,X
    TAY                       ; save sign in Y
    CLC
    ADC enemy_x_lo,X
    STA enemy_x_lo,X
    TYA                       ; restore for sign check, carry preserved
    BPL @ue_xp
    BCS @ue_xd
    DEC enemy_x_hi,X
    BCC @ue_xd                ; always
@ue_xp:
    BCC @ue_xd
    INC enemy_x_hi,X
@ue_xd:
    ; Z movement
    LDA enemy_vz,X
    TAY
    CLC
    ADC enemy_z_lo,X
    STA enemy_z_lo,X
    TYA
    BPL @ue_zp
    BCS @ue_zd
    DEC enemy_z_hi,X
    BCC @ue_zd
@ue_zp:
    BCC @ue_zd
    INC enemy_z_hi,X
@ue_zd:
    ; Spin
    INC enemy_yaw,X
    INC enemy_yaw,X
    DEX
    BPL @ue_loop
    RTS

; =====================================================================
; bilinear_height — Bilinear terrain interpolation at (x, z)
; =====================================================================
; Input:  gm_scratch_2 = x_hi, gm_scratch_3 = z_hi,
;         gm_scratch_4 = x_lo, A = z_lo
; Output: A = smoothly interpolated h*8
; Uses:   lerp_t, h_to, h_from from grid.s (free outside draw_grid)

bilinear_height:
    ; A = z_lo on entry
    AND #$3F
    PHA                       ; save fz on stack
    LDA gm_scratch_4          ; x_lo
    AND #$3F
    STA lerp_t                ; fx

    ; Build row pointer + col via get_terrain_h8 subroutine body
    ; (gm_scratch_2 = x_hi, gm_scratch_3 = z_hi already set)
    JSR get_terrain_h8        ; A = h00*8, Y = col, gm_scratch_0/1 = row ptr
    STY gm_scratch_4          ; save col
    PHA                       ; save h00

    ; Read h10 (col+1, same row); save wrapped col+1
    INY
    TYA
    AND #$1F
    TAY
    STY gm_scratch_2          ; save col+1 wrapped (safe across lerp_height)
    LDA (gm_scratch_0),Y
    AND #$F8
    STA h_to                  ; h10

    ; Lerp top row
    PLA                       ; A = h00
    JSR lerp_height           ; A = h_top
    PHA                       ; save h_top

    ; Advance pointer to next row (+32, with wrap)
    LDA gm_scratch_0
    CLC
    ADC #32
    STA gm_scratch_0
    LDA gm_scratch_1
    ADC #0
    CMP #>(height_map + $0400)
    BCC @bh_no_wrap
    LDA #>height_map
@bh_no_wrap:
    STA gm_scratch_1

    ; Read h01 (col, next row)
    LDY gm_scratch_4
    LDA (gm_scratch_0),Y
    AND #$F8
    PHA                       ; save h01

    ; Read h11 (col+1, next row) — reuse saved col+1
    LDY gm_scratch_2          ; col+1 wrapped
    LDA (gm_scratch_0),Y
    AND #$F8
    STA h_to

    ; Lerp bottom row
    PLA                       ; A = h01
    JSR lerp_height           ; A = h_bot

    ; Final lerp Z
    STA h_to                  ; h_bot
    PLA                       ; A = h_top
    TAX                       ; save h_top in X
    PLA                       ; A = fz
    STA lerp_t
    TXA                       ; A = h_top
    JMP lerp_height           ; tail call

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
