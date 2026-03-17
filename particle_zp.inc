; particle_zp.inc — Zero-page API for the particle system
;
; Include-guarded: safe to .include from multiple files.

.ifndef PARTICLE_ZP_INC
PARTICLE_ZP_INC = 1

.include "zp_layout.inc"

particle_count  = ZP_PARTICLE + 0   ; active particles (0–16)
particle_rng_lo = ZP_PARTICLE + 1   ; 16-bit LFSR lo
particle_rng_hi = ZP_PARTICLE + 2   ; 16-bit LFSR hi
ptl_draw_count  = ZP_PARTICLE + 3   ; drawn count this frame (temp during draw)

MAX_PARTICLES    = 16
PARTICLE_GRAVITY = 1                ; subtracted from vy each frame

.endif
