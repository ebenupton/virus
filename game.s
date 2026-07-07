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
;
; ── Coordinate systems ───────────────────────────────────────────────
; Two fixed-point scales are used for world coordinates:
;
;   "old scale" (rendering): 8.8 fixed point, $0100 = 1 world unit.
;     One heightmap cell = 0.25 unit = $40. The 32×32 map spans 8 units,
;     so positions wrap on an 8-unit torus (hi byte 0..7).
;     Used by: ship_pos, cam_*, obj_pos, enemies, debris, particles, grid.
;
;   "new scale" (physics): 16-bit, $2000 = 1 world unit ($20 in the hi
;     byte); the full hi-byte range 0..255 covers exactly one 8-unit
;     torus wrap, and one heightmap cell = 8 hi units (hi>>3 = cell
;     index 0..31). Gives 5 extra fractional bits for slow velocities.
;     Used by: ship_x/y/z, vel_*.  Conversion: old = new >> 5.
;
;   Terrain height h (0..31): world height = h/32 unit. In old scale
;     that is h*8 in the lo byte ("h*8"/"h×8" throughout); in new scale
;     h compares directly against a position hi byte.
;
;   Angles: 256 units per full turn, sin_table signed -127..+127.
;     ship_yaw steers the horizontal thrust direction (yaw 0 → +Z);
;     ship_roll tilts thrust away from vertical (roll 0 → straight up).

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
ship_state      = ZP_GAME + 6      ; 0=alive, 1=dead, 2=ready
debris_count    = ZP_GAME + 7      ; active debris pieces (0..4)
STATE_ALIVE     = 0
STATE_DEAD      = 1
STATE_READY     = 2

; Forward-declare grid scratch aliases (defined in grid.s, included later)
; Needed for bilinear_height to use ZP addressing
lerp_t          = ZP_GRID + 48
h_to            = ZP_GRID + 49
h_from          = ZP_GRID + 50

; Enemy state (3 dynamic enemies, ZP $D2+)
NUM_ENEMIES = 3
enemy_x_lo  = $D2
enemy_x_hi  = $D5
enemy_z_lo  = $D8
enemy_z_hi  = $DB
enemy_vx    = $DE
enemy_vz    = $E1
enemy_yaw   = $E4
enemy_idx   = $E7

; Game scratch (ZP_SHARED spares, used only during thrust/drag)
gm_scratch_0    = ZP_SHARED + 1
gm_scratch_1    = ZP_SHARED + 2
gm_scratch_2    = ZP_SHARED + 3
gm_scratch_3    = ZP_SHARED + 4
gm_scratch_4    = ZP_SHARED + 5

; =====================================================================
; Entry point ($0600)
; =====================================================================
; One-time cold start; falls through into main_loop and never returns.
;
;   init_screen()                     # CRTC + palette + both buffers
;   init_status(); draw_map() ×2      # minimap into both buffers
;   mark both buffers clean; no ship stripes recorded yet
;   zero angles / state / counters; seed particle RNG
;   reset_ship_pos()                  # ship at torus centre (4, ~1, 4)
;   init_enemies()
;   camera = (ship_x, 1.5, ship_z - 2.25)   # chase position, old scale
;
; Interrupts stay disabled forever (SEI): after boot the game touches
; hardware directly and never calls the OS again.

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
; One iteration = one rendered frame into the back buffer, then flip.
; Dirty-rectangle scheme: each buffer remembers the topmost scan line
; touched last time it was the back buffer (dirty_top_buf0/1, 0..160);
; clear_screen only erases from there down. The ship's band is tracked
; separately in 8-line stripes (ship_top/bot_buf0/1, obj_bb>>3) so
; clear_ship can erase just that strip.
;
;   while True:
;       update_camera()          # keys → ship_yaw / ship_roll
;       update_physics()         # thrust/gravity/drag → ship pos; camera
;       clear_screen()           # erase back buffer from its dirty top
;       if dirty top reached minimap rows (<48): draw_map()
;       clear_ship(); clear_particles()
;       draw_grid()              # terrain; resets/updates grid_min_sy
;       if alive: draw ship at ship_pos (yaw+roll), record its stripes
;       else:     draw debris pieces (tumbling)
;       update_enemies(); for each enemy near camera: draw at terrain+0.5
;       update_particles(); draw_particles()
;       dirty_top[back] = grid_min_sy   # objects merged their bbox in
;       draw_status(); wait_vsync(); flip_buffers()
;
; grid_min_sy is the frame's dirty top: draw_grid seeds it with the
; topmost grid pixel, and every drawn object merges obj_bb_min_sy into
; it so next frame's clear covers everything drawn this frame.

main_loop:
    JSR update_camera
    JSR update_physics
    JSR clear_screen
    ; Redraw minimap if dirty region overlapped it (rows 16-47)
    LDX back_buf_idx
    LDA dirty_top_buf0,X
    CMP #48
    BCS @no_map_redraw
    JSR draw_map
@no_map_redraw:
    JSR clear_ship
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
    BCS @ship_not_drawn
    JSR draw_object
    ; Save ship stripe range NOW (before enemies overwrite obj_bb)
    LDX back_buf_idx
    LDA obj_bb_min_sy
    LSR A
    LSR A
    LSR A
    STA ship_top_buf0,X
    LDA obj_bb_max_sy
    LSR A
    LSR A
    LSR A
    STA ship_bot_buf0,X
@ship_not_drawn:

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
    ; Merge debris dirty (only when drawn)
    LDA obj_bb_min_sy
    CMP grid_min_sy
    BCS @skip_debris
    STA grid_min_sy
@skip_debris:
    LDX gm_scratch_0
    DEX
    BPL @debris_loop

@merge_dirty:
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

    ; Copy X and Z to obj_pos (toroidal wrap + quick reject if too far)
    LDA enemy_x_lo,X
    STA obj_pos+0
    LDA enemy_x_hi,X
    LDY cam_x_hi
    JSR torus_wrap
    STA obj_pos+1
    SEC
    SBC cam_x_hi
    CLC
    ADC #2
    CMP #5
    BCS @skip_enemy           ; X distance > 2 → too far

    LDA enemy_z_lo,X
    STA obj_pos+4
    LDA enemy_z_hi,X
    LDY ship_pos+5            ; use ship Z (on 0-7 torus), not cam_z_hi
    JSR torus_wrap
    STA obj_pos+5
    SEC
    SBC ship_pos+5
    CLC
    ADC #2
    CMP #5
    BCS @skip_enemy           ; Z distance > 2 → too far

    ; Rotation
    LDA enemy_yaw,X
    STA obj_rot_angle

    ; Draw
    JSR setup_obj_view
    BCS @skip_enemy
    JSR draw_object
    ; Merge enemy dirty (only when drawn)
    LDA obj_bb_min_sy
    CMP grid_min_sy
    BCS @skip_enemy
    STA grid_min_sy
@skip_enemy:
    LDX enemy_idx
    DEX
    BPL @enemy_loop

    JSR update_particles
    JSR draw_particles

    ; Grid-only dirty top for this buffer
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
; Despite the name this now only handles rotation input; the chase
; camera position itself is set from ship_pos in update_physics.
;
; Inputs:  keyboard (System VIA port A, direct scan), ship_state,
;          ship_roll, vel_y
; Outputs: ship_yaw, ship_roll (±4/frame), roll clamped to ±90°
;
;   if ship_state != ALIVE: return       # no input while dead/ready
;   if Z: yaw -= 4;  if X: yaw += 4      # yaw wraps mod 256
;   if landed (roll==0 and vel_y==0): return   # keep ship flat on pad
;   if K: roll += 4; if M: roll -= 4
;   clamp roll into 0..64 / 192..255 (±90°): 65..127→64, 128..191→192

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
;
; Direct hardware key scan (OS is dead after boot): write the key's
; scan code to System VIA port A, read it back — bit 7 set = pressed
; (DDRA is set to $7F once per frame in update_camera).
;   if key_down(A): mem[X] += Y
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
;
; Used to jitter exhaust particle velocity; caller chains the C=0
; straight into an ADC.
;   return (random_byte() & 3) - 2

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
;
; Same >>5 conversion as position (old = new >> 5), truncated to the
; 8-bit old-scale lo byte — old-scale particle velocities are single
; signed bytes per frame.
;   return (vel[Y] >> 5) & $FF

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


; ── Persistent object positions (8.8 fixed-point, 6 bytes each) ──────
; Layout: +0/+1 = x lo/hi, +2/+3 = y lo/hi, +4/+5 = z lo/hi (matches
; obj_pos). Derived from the new-scale ship_x/y/z (>>5) every frame in
; update_physics; this is what the grid, camera and object code read.
ship_pos      = $E9               ; ship old-scale position (6 bytes ZP, $E9-$EE)

; (enemy state arrays in ZP, defined at top of file)

; ── Debris state (ship destruction) ──────────────────────────────────
; Up to 4 tumbling fragments, struct-of-arrays. Positions are old-scale
; 8.8; velocities are signed old-scale lo bytes per frame (vy has
; per-frame gravity applied in update_debris). rot/roll spin the mesh.
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
; Ship state machine + flight integration, once per frame.
;
; Inputs:  ship_state, ship_x/y/z + vel_* (new scale), ship_yaw/roll,
;          keys L (thrust) and SPACE (respawn) via VIA scan
; Outputs: ship_x/y/z, vel_* updated; ship_pos (old scale) refreshed;
;          cam_x/y/z updated to chase position; may spawn an exhaust
;          particle; may transition ship_state (via debris/respawn)
;
;   if DEAD:  update_debris(); when all gone and SPACE released → READY
;   if READY: wait for SPACE → respawn_ship()
;   # ALIVE:
;   vel_y -= GRAVITY                                     # 1. gravity
;   if L held:                                           # 2. thrust
;       # unit thrust vector from roll (tilt) and yaw (heading):
;       #   (sin(roll)·sin(yaw), cos(roll), sin(roll)·cos(yaw))
;       vel += THRUST * thrust_vec >> 7    # per axis, via smul_shr7
;       if room: spawn exhaust particle at ship_pos with
;           v = -EXHAUST * thrust_vec + random[-2..1] + ship vel (old scale)
;   vel -= vel >> 6   per axis                           # 3. drag
;   pos += vel        per axis (16-bit)                  # 4. integrate
;   clamp ship_y to [0, MAX_POS_Y]; ceiling also zeroes vel_y  # 5.
;   ship_pos = pos >> 5   (old scale, for all rendering) # 5c.
;   check_terrain()   # may land (clamp) or crash (destroy_ship)  # 5d.
;   cam_x = ship_x; cam_z = ship_z - 2.25                # 6. chase cam
;   # 7. camera height: focus terrain when skimming, else follow ship
;   if ship_y - terrain_h < 0.25: cam_y = terrain_h + 0.25 + 1.5
;   else:                         cam_y = ship_y + 1.5

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

    ; 7. Camera Y — terrain focus when ship is close to ground
    ; Bilinear terrain height at ship's old-scale XZ
    LDA ship_pos+1
    STA gm_scratch_2            ; x_hi
    LDA ship_pos+5
    STA gm_scratch_3            ; z_hi
    LDA ship_pos+0
    STA gm_scratch_4            ; x_lo
    LDA ship_pos+4              ; z_lo
    JSR bilinear_height         ; A = h*8

    ; 16-bit gap: (ship_pos[3]:ship_pos[2]) - ($00:h*8)
    STA gm_scratch_0            ; save terrain h*8
    LDA ship_pos+2
    SEC
    SBC gm_scratch_0            ; lo byte of gap
    TAX                         ; save gap_lo
    LDA ship_pos+3
    SBC #0                      ; hi byte of gap (with borrow)
    BCC @use_terrain            ; negative → ship below terrain
    BNE @use_ship               ; hi > 0 → gap >= 256 → well above
    CPX #$40                    ; gap_lo < 0.25?
    BCS @use_ship               ; >= 0.25 → ship focus

@use_terrain:
    ; cam_y = h*8 + $01C0 (terrain + 0.25 + CAM_HEIGHT); C=0 from BCC entry
    LDA gm_scratch_0
    ADC #$C0                    ; C known 0 from BCC
    STA cam_y_lo
    LDA #$01
    ADC #0
    BNE @cam_done               ; always (A >= 1)

@use_ship:
    CLC
    LDA ship_pos+2
    ADC #CAM_HEIGHT_LO
    STA cam_y_lo
    LDA ship_pos+3
    ADC #CAM_HEIGHT_HI
@cam_done:
    STA cam_y_hi
    RTS

; =====================================================================
; smul_shr7 — Signed multiply then shift right 7
; =====================================================================
; Input:  A = first arg, math_b set
; Output: A = (A * math_b) >> 7
;
; Signed 8×8→16 product, keeping bits 14:7 — i.e. multiply by a
; sin_table value (±127 ≈ ±1.0 in 1.7 fixed point) with unity gain.
; Implemented as hi byte shifted left once, pulling in the top bit of
; the lo byte.

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
;
; cos(a) = sin(a + 64): one 256-entry table serves both (index wraps).

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
;
;   vel[X] += sign_extend(A)    # 16-bit
; The hi-byte fixup branches on the accel's sign instead of building a
; sign-extended hi byte: positive propagates carry (INC), negative
; propagates borrow (DEC when no carry).

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
;
;   vel[X] -= vel[X] >> 6       # exponential decay, ~1.5%/frame
; The >>6 is computed as a <<2 of the 16-bit value taking the top bits
; ((hi<<2) | (lo>>6)); the subtraction's hi byte uses drag_hi = 0 for
; positive vel and $FF for negative (arithmetic shift sign extension),
; folded into the SBC immediate via the BIT-skip trick.

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
; Point test against the ship's current cell (no interpolation).
;
; Inputs:  ship_x/y/z (new scale), ship_roll
; Outputs: nothing if airborne; on plateau landing clamps ship_y/roll
;          and kills downward velocity; otherwise tail-calls
;          destroy_ship (crash)
; Clobbers: A, X, Y, gm_scratch_0-3
;
;   col = ship_x_hi >> 3; row = ship_z_hi >> 3      # cell 0..31 each
;   cell = height_map[row*32 + col]; h = cell >> 3
;   if h < ship_y_hi: return                        # above terrain
;   if h == 31 (plateau) and |roll| < 8:            # flat over a pad
;       ship_y_hi = h; roll = 0
;       if descending: ship_y_lo = 0; vel_y = 0     # settle
;       # (ascending keeps y_lo/vel so a takeoff isn't cancelled)
;   else: destroy_ship()

check_terrain:
    ; Compute heightmap col from new-scale ship_x: ship_x_hi >> 3
    LDA ship_x_hi
    LSR A
    LSR A
    LSR A
    TAY                       ; Y = col (0..31, 3 LSRs guarantee 5 bits)

    ; Compute heightmap row from new-scale ship_z: ship_z_hi >> 3
    LDA ship_z_hi
    LSR A
    LSR A
    LSR A

    ; Build pointer: height_map + row * 32
    ; Trick: pre-load the hi byte with >height_map/4, then let the two
    ; ROLs of the row<<5 shift both restore the base and merge in the
    ; row's top 2 bits (works because the map is 1K-aligned).
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
; Input:  gm_scratch_2 = x_hi, gm_scratch_3 = z_hi,
;         gm_scratch_4 = x_lo, A = z_lo  (all old-scale)
; Output: A = h*8 (0..248), Y = col, gm_scratch_0/1 = row ptr
; Preserves: X
; Clobbers: A, Y, gm_scratch_0, gm_scratch_1
;
; Old-scale flavour of the cell lookup (cell = $40 = 0.25 unit, so the
; cell index is bits 12:6 of the 8.8 position):
;   col = ((x_hi << 2) | (x_lo >> 6)) & 31
;   row = ((z_hi << 2) | (z_lo >> 6)) & 31
;   return height_map[row*32 + col] & $F8       # h*8
; The row pointer is left in gm_scratch_0/1 so callers (bilinear_height)
; can read neighbouring cells with (ptr),Y.

get_terrain_h8:
    ; col = ((x_hi << 2) | (x_lo >> 6)) & $1F → Y
    PHA                       ; save z_lo
    LDA gm_scratch_4          ; x_lo
    JSR @gt_combine           ; A = col
    TAY                       ; Y = col

    ; row = ((z_hi << 2) | (z_lo >> 6)) & $1F → build pointer
    LDA gm_scratch_3
    STA gm_scratch_2          ; z_hi into gm_scratch_2 for @gt_combine
    LDA #>height_map / 4
    STA gm_scratch_1          ; init pointer hi early (safe: @gt_combine won't touch it)
    PLA                       ; z_lo
    JSR @gt_combine           ; A = row
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

; Shared: A=lo byte, gm_scratch_2=hi byte → A = ((hi<<2)|(lo>>6)) & $1F
@gt_combine:
    ASL A
    ROL A
    ROL A
    AND #$03
    STA gm_scratch_0
    LDA gm_scratch_2
    ASL A
    ASL A
    ORA gm_scratch_0
    AND #$1F
    RTS

; =====================================================================
; destroy_ship — Set dead flag, spawn 3 debris pieces
; =====================================================================
; (Spawns 4 pieces; banner kept for history.)
;
; Inputs:  ship_pos (old scale)
; Outputs: ship_state = DEAD, debris_count = 4, debris arrays filled
; Clobbers: A, X
;
;   for each of 4 pieces:
;       pos = ship_pos + (0, +$10, 0)      # start slightly above ship
;       vy = 10 + rnd(0..11)               # up
;       vx, vz = rnd(-8..7)                # outward scatter
;       rot = rnd(); roll = rot ^ $A5      # decorrelated tumble phases

destroy_ship:
    LDA #STATE_DEAD
    STA ship_state
    LDA #4
    STA debris_count

    ; Init 4 debris pieces at ship's old-scale position
    LDX #3
@ds_loop:
    LDA ship_pos +0
    STA debris_x_lo,X
    LDA ship_pos +1
    STA debris_x_hi,X
    LDA ship_pos +2
    CLC
    ADC #$10                  ; start debris slightly above ship
    STA debris_y_lo,X
    LDA ship_pos +3
    ADC #0
    STA debris_y_hi,X
    LDA ship_pos +4
    STA debris_z_lo,X
    LDA ship_pos +5
    STA debris_z_hi,X

    ; Random upward velocity (10..21)
    JSR random_byte
    AND #$0B                  ; 0-11 (75% of original 0-15 variable range)
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
; READY + SPACE → here (from update_physics). Zeroes state/angles,
; rerolls the enemies, then tail-calls reset_ship_pos.

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
;
; vel_x_hi..ship_z_hi are 12 contiguous ZP bytes: one loop clears all
; three velocities and the position, then the start position is poked
; in. New-scale $80 hi = 4.0 units (torus centre); y_hi $1F ≈ 0.97
; units, just above the tallest terrain (31/32).

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
; Inputs:  debris arrays, debris_count
; Outputs: debris arrays updated; pieces at/below terrain removed
;          (swap-and-pop), debris_count decremented
; Clobbers: A, X, Y, gm_scratch_0-3 (via get_terrain_h8)
;
;   for i in count-1 .. 0:
;       vy[i] -= 1                          # gravity
;       pos[i] += sign_extend(v[i])         # per axis, 16-bit
;       rot[i] += 7; roll[i] += 1           # spin + slower tumble
;       if y[i] <= terrain_h8 at (x,z):     # cell lookup, no interp
;           swap slot count-1 into i; count -= 1; retry slot i

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
    JSR get_terrain_h8        ; A = h*8 (X preserved, approx cell)
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
; torus_wrap — Wrap A to nearest image of Y on 8-unit torus
; =====================================================================
; Input:  A = position hi byte, Y = camera hi byte
; Output: A = wrapped position hi byte
; Preserves: X
;
; Old-scale hi bytes = whole world units; the map is an 8-unit torus.
; Picks the image of A that lies within [Y-4, Y+3] so distances and
; projection see the nearest copy:
;   return Y + (((A - Y + 4) & 7) - 4)
; (Uses h_from as scratch — safe, grid isn't running.)

torus_wrap:
    ; A=pos_hi, Y=cam_hi → A=wrapped pos_hi
    STY h_from
    SEC
    SBC h_from
    CLC
    ADC #4
    AND #$07
    CLC
    ADC h_from
    SEC
    SBC #4
    RTS

; =====================================================================
; init_enemies — Randomize position and velocity for all enemies
; =====================================================================
; Clobbers: A, X (and RNG state)
;
; Positions are old-scale 8.8 but free-running over the full 16-bit
; range; torus_wrap folds them near the camera at draw time. Each
; enemy gets one random byte reused (EOR-scrambled) across x/z to save
; RNG calls, a random yaw, and axis velocities in [-3..+4].

init_enemies:
    LDX #NUM_ENEMIES-1
@ie_loop:
    JSR random_byte
    STA enemy_x_lo,X
    STA enemy_z_hi,X
    EOR #$C3
    STA enemy_x_hi,X
    STA enemy_z_lo,X
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
; Clobbers: A, X, Y
;
;   for each enemy:
;       x += sign_extend(vx); z += sign_extend(vz)   # 16-bit adds
;       yaw += 1                                     # slow spin
; Same sign-extension-by-branch trick as add_accel. No terrain or
; player interaction; Y position is recomputed from the terrain at
; draw time (main_loop).

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
;
; Full bilinear fetch, used for the camera height focus and to sit
; enemies on the terrain (the grid renderer itself never needs it —
; grid vertices lie on cell corners).
;
;   fx = x_lo & $3F; fz = z_lo & $3F          # position within cell /64
;   h00 = cell[row][col]    h10 = cell[row][col+1]     # via row ptr
;   h01 = cell[row+1][col]  h11 = cell[row+1][col+1]   # +32 bytes, wraps
;   return lerp(lerp(h00,h10,fx), lerp(h01,h11,fx), fz)   # all h*8
; lerp() is grid.s lerp_height (LUT-quantised, see interp_lut).

bilinear_height:
    ; A = z_lo on entry
    TAY                       ; Y = z_lo (full, for get_terrain_h8)
    AND #$3F
    PHA                       ; save fz on stack
    LDA gm_scratch_4          ; x_lo
    AND #$3F
    STA lerp_t                ; fx

    ; Build row pointer + col via get_terrain_h8
    ; (gm_scratch_2 = x_hi, gm_scratch_3 = z_hi, gm_scratch_4 = x_lo already set)
    TYA                       ; A = z_lo (full, for cell selection)
    JSR get_terrain_h8        ; A = h00*8, Y = col, gm_scratch_0/1 = row ptr
    STY gm_scratch_4          ; save col
    PHA                       ; save h00

    ; Read h10 (col+1, same row)
    INY
    TYA
    AND #$1F
    TAY                       ; Y = col+1 wrapped
    LDA (gm_scratch_0),Y
    AND #$F8
    STA h_to                  ; h10

    ; Lerp top row (Y preserved across lerp_height)
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

    ; Read h11 (col+1, next row) — Y still has col+1
    LDA (gm_scratch_0),Y
    AND #$F8
    STA h_to                  ; h11 → h_to for bottom lerp

    ; Read h01 (col, next row)
    LDY gm_scratch_4
    LDA (gm_scratch_0),Y
    AND #$F8

    ; Lerp bottom row: A = h01, h_to = h11
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
