; particle.s — 3D particle system for BBC Micro
;
; Provides: init_particles, clear_particles, update_particles, draw_particles,
;           random_byte
; Requires: particle_zp.inc, object_zp.inc, raster_zp.inc, math_zp.inc,
;           clip_zp.inc, video_zp.inc
; Emission is handled inline in game.s (thrust exhaust).

.include "particle_zp.inc"
.include "object_zp.inc"
.include "raster_zp.inc"
.include "math_zp.inc"
.include "clip_zp.inc"
.include "video_zp.inc"

; ── Data arrays (CODE segment, zeroed at load) ────────────────────────

; Particle state (160 bytes)
ptl_x_lo:  .res 16   ; world X fractional
ptl_x_hi:  .res 16   ; world X integer
ptl_y_lo:  .res 16   ; world Y fractional
ptl_y_hi:  .res 16   ; world Y integer
ptl_z_lo:  .res 16   ; world Z fractional
ptl_z_hi:  .res 16   ; world Z integer
ptl_vx:    .res 16   ; signed X velocity
ptl_vy:    .res 16   ; signed Y velocity
ptl_vz:    .res 16   ; signed Z velocity
ptl_timer: .res 16   ; countdown timer (GC when 0)

; Clear arrays (98 bytes) — slots 0–15 = buf0, 16–31 = buf1
ptl_clr_a0_lo:  .res 32   ; pixel byte addr lo
ptl_clr_a0_hi:  .res 32   ; pixel byte addr hi
ptl_clr_mask:   .res 32   ; AND mask ($D5 left / $EA right)
ptl_clr_count:  .res 2    ; [0]=buf0 drawn count, [1]=buf1 drawn count

; (init_particles inlined into game.s entry)

; =====================================================================
; random_byte — 16-bit Galois LFSR, returns random byte in A
; =====================================================================
; Preserves: X, Y

random_byte:
    LDA particle_rng_lo
    ASL A
    ROL particle_rng_hi
    BCC @no_tap
    EOR #$2D
@no_tap:
    STA particle_rng_lo
    RTS

; =====================================================================
; clear_particles — AND-clear previously drawn particles from back buffer
; =====================================================================
; Runs after clear_screen. Uses back_buf_idx to select array half.

clear_particles:
    LDX back_buf_idx
    LDA ptl_clr_count,X
    BEQ @done
    ; Array offset: 0 for buf0, 16 for buf1
    LDY #0
    CPX #0
    BEQ @start
    LDY #16
@start:
    STY gm_scratch_2            ; save array base
    CLC
    ADC gm_scratch_2            ; A = count + base (A still has count from LDA above)
    STA gm_scratch_3            ; end index
    LDX gm_scratch_2
@loop:
    LDA ptl_clr_a0_lo,X
    STA ZP_SHARED+1
    LDA ptl_clr_a0_hi,X
    STA ZP_SHARED+2
    LDY #0
    LDA #0
    STA (ZP_SHARED+1),Y
    INX
    CPX gm_scratch_3
    BCC @loop
    ; Zero the count for this buffer
    LDX back_buf_idx
    LDA #0
    STA ptl_clr_count,X
@done:
    RTS

; =====================================================================
; update_particles — Decrement timer, apply gravity + physics, GC
; =====================================================================

update_particles:
    LDX particle_count
    BNE @has_ptl
    RTS
@has_ptl:
    DEX
@loop:
    ; Timer check: GC when reaches 0
    DEC ptl_timer,X
    BNE @ptl_alive
    JMP @gc
@ptl_alive:

    ; Gravity: decrease upward velocity
    DEC ptl_vy,X

    ; Y axis: sign-extend ptl_vy and add to ptl_y_lo:ptl_y_hi
    LDA ptl_vy,X
    CLC
    ADC ptl_y_lo,X
    STA ptl_y_lo,X
    LDY ptl_vy,X           ; reload sign (LDY preserves C)
    BMI @vy_neg
    BCC @vy_done
    INC ptl_y_hi,X
@vy_done:

    ; X axis: sign-extend ptl_vx and add to ptl_x_lo:ptl_x_hi
    LDA ptl_vx,X
    CLC
    ADC ptl_x_lo,X
    STA ptl_x_lo,X
    LDY ptl_vx,X
    BMI @vx_neg
    BCC @vx_done
    INC ptl_x_hi,X
@vx_done:

    ; Z axis: sign-extend ptl_vz and add to ptl_z_lo:ptl_z_hi
    LDA ptl_vz,X
    CLC
    ADC ptl_z_lo,X
    STA ptl_z_lo,X
    LDY ptl_vz,X
    BMI @vz_neg
    BCC @vz_done
    INC ptl_z_hi,X
@vz_done:

    ; GC: remove if particle Y <= terrain height (clean 16-bit compare)
    ; Terrain height = $00:h*8 (hi byte always 0, lo byte = h*8)
    ; Particle Y = ptl_y_hi:ptl_y_lo
    LDA ptl_y_hi,X
    BMI @gc                   ; negative → below any terrain
    BNE @ptl_next             ; y_hi > 0 → above terrain (terrain hi is always 0)
    ; y_hi == 0 == terrain_hi: compare lo bytes
    LDA ptl_x_hi,X
    STA gm_scratch_2
    LDA ptl_z_hi,X
    STA gm_scratch_3
    JSR get_terrain_h8        ; A = h*8
    CMP ptl_y_lo,X            ; h*8 vs y_lo
    BCS @gc                   ; h*8 >= y_lo → at or below terrain

@ptl_next:
    DEX
    BMI @done
    JMP @loop
@done:
    RTS

    ; Outlined negative velocity handlers (C preserved from ADC above)
@vy_neg:
    LDA ptl_y_hi,X
    ADC #$FF
    STA ptl_y_hi,X
    JMP @vy_done
@vx_neg:
    LDA ptl_x_hi,X
    ADC #$FF
    STA ptl_x_hi,X
    JMP @vx_done
@vz_neg:
    LDA ptl_z_hi,X
    ADC #$FF
    STA ptl_z_hi,X
    JMP @vz_done

@gc:
    ; Swap-and-pop: copy last particle to slot X, decrement count
    DEC particle_count
    LDY particle_count
    CPX particle_count      ; X == new count means X was the last slot
    BEQ @gc_dec_done

    LDA ptl_x_lo,Y
    STA ptl_x_lo,X
    LDA ptl_x_hi,Y
    STA ptl_x_hi,X
    LDA ptl_y_lo,Y
    STA ptl_y_lo,X
    LDA ptl_y_hi,Y
    STA ptl_y_hi,X
    LDA ptl_z_lo,Y
    STA ptl_z_lo,X
    LDA ptl_z_hi,Y
    STA ptl_z_hi,X
    LDA ptl_vx,Y
    STA ptl_vx,X
    LDA ptl_vy,Y
    STA ptl_vy,X
    LDA ptl_vz,Y
    STA ptl_vz,X
    LDA ptl_timer,Y
    STA ptl_timer,X

@gc_dec_done:
    DEX
    BMI @gc_exit
    JMP @loop
@gc_exit:
    RTS

; =====================================================================
; draw_particles — Project 3D→2D, OR-draw single white pixel, record clear
; =====================================================================
; Clips against X and Z frustum planes. Single-pixel only.

draw_particles:
    LDA particle_count
    BNE @has_particles
    RTS
@has_particles:

    ; Compute buf_off: 0 for buf0, 16 for buf1
    LDA back_buf_idx
    BEQ @buf0
    LDA #16
@buf0:
    STA ptl_draw_count          ; record index starts at buf_off

    LDX #0                      ; particle index
@loop:
    CPX particle_count
    BCC @loop_body
    JMP @loop_done
@loop_body:

    ; ── View-space transform ──
    ; view_x = ptl_x - cam_x
    LDA ptl_x_lo,X
    SEC
    SBC cam_x_lo
    STA obj_view_x
    LDA ptl_x_hi,X
    SBC cam_x_hi
    STA obj_view_x+1

    ; view_y = cam_y - ptl_y
    LDA cam_y_lo
    SEC
    SBC ptl_y_lo,X
    STA obj_view_y
    LDA cam_y_hi
    SBC ptl_y_hi,X
    STA obj_view_y+1

    ; view_z = ptl_z - cam_z
    LDA ptl_z_lo,X
    SEC
    SBC cam_z_lo
    STA obj_view_z
    LDA ptl_z_hi,X
    SBC cam_z_hi
    STA obj_view_z+1

    ; Z visibility: skip if z <= 0
    BMI @far_skip
    ORA obj_view_z
    BNE @z_ok
@far_skip:
    JMP @next_particle
@z_ok:

    ; ── Clip plane checks ──
    ; Left: view_x + HALF_GRID_X < 0?
    LDA obj_view_x
    CLC
    ADC #HALF_GRID_X_LO
    LDA obj_view_x+1
    ADC #HALF_GRID_X_HI
    BMI @clip_skip
    ; Right: HALF_GRID_X - view_x < 0?
    LDA #HALF_GRID_X_LO
    SEC
    SBC obj_view_x
    LDA #HALF_GRID_X_HI
    SBC obj_view_x+1
    BMI @clip_skip
    ; Near: view_z - CLIP_NEAR < 0?
    LDA obj_view_z
    SEC
    SBC #CLIP_NEAR_LO
    LDA obj_view_z+1
    SBC #CLIP_NEAR_HI
    BMI @clip_skip
    ; Far: CLIP_FAR - view_z < 0?
    LDA #CLIP_FAR_LO
    SEC
    SBC obj_view_z
    LDA #CLIP_FAR_HI
    SBC obj_view_z+1
    BMI @clip_skip

    ; ── Projection ──
    ; Save particle index (X clobbered by projection)
    STX gm_scratch_0

    ; Reciprocal of view_z
    LDA obj_view_z
    STA math_b
    LDA obj_view_z+1
    JSR recip8
    STA clip_n

    ; Project X → screen X
    LDA obj_view_x
    LDX obj_view_x+1
    JSR project_coord
    LDA #64
    LDX #127
    JSR clamp_add
    STA raster_x0

    ; Project Y → screen Y
    LDA obj_view_y
    LDX obj_view_y+1
    JSR project_coord
    LDA #16
    LDX #159
    JSR clamp_add
    STA raster_y0

    ; init_base → raster_base, Y=sub_row
    JSR init_base

    ; OR mask from X parity
    LDA raster_x0
    LSR A
    LDA #$2A                    ; left pixel (white)
    BCC @left
    LDA #$15                    ; right pixel (white)
@left:
    STA gm_scratch_2            ; OR mask

    ; Plot single pixel
    LDA gm_scratch_2
    ORA (raster_base),Y
    STA (raster_base),Y

    ; Record clear address
    TYA
    ORA raster_base             ; addr_lo (base low 3 bits=0, Y=0..7)
    LDX ptl_draw_count
    STA ptl_clr_a0_lo,X
    LDA raster_base+1
    STA ptl_clr_a0_hi,X

    ; Advance record index
    INC ptl_draw_count

    ; Restore particle index
    LDX gm_scratch_0

@clip_skip:
@next_particle:
    INX
    JMP @loop

@loop_done:
    ; Store drawn count = ptl_draw_count - buf_off
    LDA ptl_draw_count
    LDX back_buf_idx
    BEQ @store_count          ; buf0: count = ptl_draw_count, X=0
    SEC
    SBC #16                   ; buf1: count = ptl_draw_count - 16
@store_count:
    STA ptl_clr_count,X
    RTS
