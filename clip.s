; clip.s — Cohen-Sutherland 3D line clipper (4 clip planes)
;
; Provides: clip_line_left, clip_line_right, clip_line_near, clip_line_far,
;           project_and_draw
; Requires: raster_zp.inc, math_zp.inc, grid_zp.inc
;           recip8, umul8x8, smul8x8, init_base, draw_line
;
; ── Pipeline ────────────────────────────────────────────────────────
; The caller (object.s edge loop) loads a camera-space segment into
; clip_x0..clip_z1 (16-bit signed 8.8, one lo/hi pair per coordinate)
; and runs the planes in sequence, abandoning the edge on any C=1
; reject:
;   clip_line_left → clip_line_right → clip_line_near → clip_line_far
;   → project_and_draw
; The clip volume is a box, not a view pyramid: |x| <= HALF_GRID_X and
; Z_NEAR_BOUND <= z <= Z_FAR_BOUND (the grid's extent).  There are no
; Y planes: the projected screen Y is clamped by clamp_add instead.
;
; ── Common plane-clipper pattern ────────────────────────────────────
; All four clip_line_* routines share one structure; only the axis,
; the plane constant and the outside-test sign differ:
;
;   def clip_line_plane(P0, P1):
;       out0 = outside(P0)            # sign bit of 16-bit coord-plane
;       out1 = outside(P1)            #   (or plane-coord) difference
;       if not out0 and not out1: return ACCEPT   # trivial accept
;       if out0 and out1:         return REJECT   # trivial reject
;       if not out0: swap(P0, P1)     # canonical: P0 out, P1 in
;       # parametric intersection, t in (0,1) as a 0.8 fraction:
;       t = (plane - P0.axis) / (P1.axis - P0.axis)    # div_16_8
;       for c in the other two coordinates:            # lerp_coord
;           P0.c += (t * (P1.c - P0.c)) >> 8
;       P0.axis = plane               # exact — no rounding residue
;       return ACCEPT
;
; N and D are both computed outside-minus-inside-wards so they are
; positive by construction, as div_16_8 requires.  The swap means a
; clipped edge can come back with its endpoints exchanged — harmless,
; the rasterizer is direction-agnostic.  The outside tests keep only
; the sign of the 16-bit difference: the lo-byte ADC/SBC is executed
; purely to feed its carry into the hi-byte operation.

.include "raster_zp.inc"
.include "math_zp.inc"
.include "grid_zp.inc"
.include "clip_zp.inc"

; ── Internal workspace (ZP_CLIP internal) ─────────────────────────
clip_d      = ZP_CLIP + 17    ; 2 bytes — scratch / division denominator
clip_q      = ZP_CLIP + 19    ; 1 byte  — t quotient (0.8)
clip_out    = ZP_CLIP + 20    ; 1 byte  — sign flag for lerp

; ── Clip plane constants ──────────────────────────────────────────
; Left: -HALF_GRID_X
CLIP_LEFT_LO = (-HALF_GRID_X) & $FF
CLIP_LEFT_HI = ((-HALF_GRID_X) >> 8) & $FF

; Right: +HALF_GRID_X
CLIP_RIGHT_LO = HALF_GRID_X & $FF
CLIP_RIGHT_HI = (HALF_GRID_X >> 8) & $FF

; Near: Z_NEAR_BOUND
CLIP_NEAR_LO = Z_NEAR_BOUND & $FF
CLIP_NEAR_HI = (Z_NEAR_BOUND >> 8) & $FF

; Far: Z_FAR_BOUND
CLIP_FAR_LO = Z_FAR_BOUND & $FF
CLIP_FAR_HI = (Z_FAR_BOUND >> 8) & $FF

; =====================================================================
; clip_swap — Swap P0 and P1 endpoints (shared by all clip routines)
; =====================================================================
; Swaps clip_x0..clip_z0 with clip_x1..clip_z1 (6 byte pairs)
; Clobbers: A, X, Y

clip_swap:
    LDX #5
@loop:
    LDA clip_x0,X
    LDY clip_x1,X
    STA clip_x1,X
    TYA
    STA clip_x0,X
    DEX
    BPL @loop
    RTS

; =====================================================================
; clip_line_left — Clip line to left plane (x >= -HALF_GRID_X)
; =====================================================================
; Inputs:  clip_x0..clip_z1 set
; Outputs: C=0 accept (endpoints may be modified), C=1 reject
; Clobbers: A, X, Y, clip workspace
;
; Instance of the common pattern (see header): axis = X, plane =
; -HALF_GRID_X, outside(P) = (P.x + HALF_GRID_X) < 0; lerps Y and Z.

clip_line_left:
    ; -- Test P0: outside if x0 + HALF_GRID_X < 0 --
    LDA clip_x0
    CLC
    ADC #HALF_GRID_X_LO
    LDA clip_x0+1
    ADC #HALF_GRID_X_HI
    BMI @p0_out

    ; P0 inside — test P1
    LDA clip_x1
    CLC
    ADC #HALF_GRID_X_LO
    LDA clip_x1+1
    ADC #HALF_GRID_X_HI
    BMI @swap_and_clip

    ; Both inside → accept
    CLC
    RTS

@p0_out:
    ; P0 outside — test P1
    LDA clip_x1
    CLC
    ADC #HALF_GRID_X_LO
    LDA clip_x1+1
    ADC #HALF_GRID_X_HI
    BPL @clip_p0

    ; Both outside → reject
    SEC
    RTS

@swap_and_clip:
    JSR clip_swap

@clip_p0:
    ; P0 outside left, P1 inside
    ; N = -HALF_GRID_X - x0 (positive since x0 < plane)
    LDA #CLIP_LEFT_LO
    SEC
    SBC clip_x0
    STA clip_n
    LDA #CLIP_LEFT_HI
    SBC clip_x0+1
    STA clip_n+1

    ; D = x1 - x0 (positive since x1 > x0)
    LDA clip_x1
    SEC
    SBC clip_x0
    STA clip_d
    LDA clip_x1+1
    SBC clip_x0+1
    STA clip_d+1

    ; t = N / D as 0.8 quotient
    JSR div_16_8

    ; Interpolate Y: y0 += t * (y1 - y0)
    LDX #2
    JSR lerp_coord

    ; Interpolate Z: z0 += t * (z1 - z0)
    LDX #4
    JSR lerp_coord

    ; Set x0 = -HALF_GRID_X exactly
    LDA #CLIP_LEFT_LO
    STA clip_x0
    LDA #CLIP_LEFT_HI
    STA clip_x0+1

    ; Accept
    CLC
    RTS

; =====================================================================
; clip_line_right — Clip line to right plane (x <= +HALF_GRID_X)
; =====================================================================
; Inputs:  clip_x0..clip_z1 set
; Outputs: C=0 accept, C=1 reject
; Clobbers: A, X, Y, clip workspace
;
; Instance of the common pattern (see header): axis = X, plane =
; +HALF_GRID_X, outside(P) = (HALF_GRID_X - P.x) < 0; lerps Y and Z.

clip_line_right:
    ; -- Test P0: outside if HALF_GRID_X - x0 < 0 --
    LDA #CLIP_RIGHT_LO
    SEC
    SBC clip_x0
    LDA #CLIP_RIGHT_HI
    SBC clip_x0+1
    BMI @p0_out

    ; P0 inside — test P1
    LDA #CLIP_RIGHT_LO
    SEC
    SBC clip_x1
    LDA #CLIP_RIGHT_HI
    SBC clip_x1+1
    BMI @swap_and_clip

    ; Both inside → accept
    CLC
    RTS

@p0_out:
    ; P0 outside — test P1
    LDA #CLIP_RIGHT_LO
    SEC
    SBC clip_x1
    LDA #CLIP_RIGHT_HI
    SBC clip_x1+1
    BPL @clip_p0

    ; Both outside → reject
    SEC
    RTS

@swap_and_clip:
    JSR clip_swap

@clip_p0:
    ; P0 outside right, P1 inside
    ; N = x0 - HALF_GRID_X (positive since x0 > plane)
    LDA clip_x0
    SEC
    SBC #CLIP_RIGHT_LO
    STA clip_n
    LDA clip_x0+1
    SBC #CLIP_RIGHT_HI
    STA clip_n+1

    ; D = x0 - x1 (positive since x0 > x1)
    LDA clip_x0
    SEC
    SBC clip_x1
    STA clip_d
    LDA clip_x0+1
    SBC clip_x1+1
    STA clip_d+1

    JSR div_16_8

    LDX #2
    JSR lerp_coord
    LDX #4
    JSR lerp_coord

    ; Set x0 = +HALF_GRID_X
    LDA #CLIP_RIGHT_LO
    STA clip_x0
    LDA #CLIP_RIGHT_HI
    STA clip_x0+1

    CLC
    RTS

; =====================================================================
; clip_line_near — Clip line to near plane (z >= Z_NEAR_BOUND)
; =====================================================================
; Inputs:  clip_x0..clip_z1 set
; Outputs: C=0 accept, C=1 reject
; Clobbers: A, X, Y, clip workspace
;
; Instance of the common pattern (see header): axis = Z, plane =
; Z_NEAR_BOUND, outside(P) = (P.z - Z_NEAR_BOUND) < 0; lerps X and Y.
; Accepted output guarantees z >= Z_NEAR_BOUND (>= 256), which is what
; lets project_and_draw assume recip8 never sees z_hi = 0.

clip_line_near:
    ; -- Test P0: outside if z0 - Z_NEAR_BOUND < 0 --
    LDA clip_z0
    SEC
    SBC #CLIP_NEAR_LO
    LDA clip_z0+1
    SBC #CLIP_NEAR_HI
    BMI @p0_out

    ; P0 inside — test P1
    LDA clip_z1
    SEC
    SBC #CLIP_NEAR_LO
    LDA clip_z1+1
    SBC #CLIP_NEAR_HI
    BMI @swap_and_clip

    ; Both inside → accept
    CLC
    RTS

@p0_out:
    ; P0 outside — test P1
    LDA clip_z1
    SEC
    SBC #CLIP_NEAR_LO
    LDA clip_z1+1
    SBC #CLIP_NEAR_HI
    BPL @clip_p0

    ; Both outside → reject
    SEC
    RTS

@swap_and_clip:
    JSR clip_swap

@clip_p0:
    ; P0 outside near, P1 inside
    ; N = Z_NEAR_BOUND - z0 (positive since z0 < plane)
    LDA #CLIP_NEAR_LO
    SEC
    SBC clip_z0
    STA clip_n
    LDA #CLIP_NEAR_HI
    SBC clip_z0+1
    STA clip_n+1

    ; D = z1 - z0 (positive since z1 > z0)
    LDA clip_z1
    SEC
    SBC clip_z0
    STA clip_d
    LDA clip_z1+1
    SBC clip_z0+1
    STA clip_d+1

    JSR div_16_8

    ; Lerp X
    LDX #0
    JSR lerp_coord
    ; Lerp Y
    LDX #2
    JSR lerp_coord

    ; Set z0 = Z_NEAR_BOUND
    LDA #CLIP_NEAR_LO
    STA clip_z0
    LDA #CLIP_NEAR_HI
    STA clip_z0+1

    CLC
    RTS

; =====================================================================
; clip_line_far — Clip line to far plane (z <= Z_FAR_BOUND)
; =====================================================================
; Inputs:  clip_x0..clip_z1 set
; Outputs: C=0 accept, C=1 reject
; Clobbers: A, X, Y, clip workspace
;
; Instance of the common pattern (see header): axis = Z, plane =
; Z_FAR_BOUND, outside(P) = (Z_FAR_BOUND - P.z) < 0; lerps X and Y.

clip_line_far:
    ; -- Test P0: outside if Z_FAR_BOUND - z0 < 0 --
    LDA #CLIP_FAR_LO
    SEC
    SBC clip_z0
    LDA #CLIP_FAR_HI
    SBC clip_z0+1
    BMI @p0_out

    ; P0 inside — test P1
    LDA #CLIP_FAR_LO
    SEC
    SBC clip_z1
    LDA #CLIP_FAR_HI
    SBC clip_z1+1
    BMI @swap_and_clip

    ; Both inside → accept
    CLC
    RTS

@p0_out:
    ; P0 outside — test P1
    LDA #CLIP_FAR_LO
    SEC
    SBC clip_z1
    LDA #CLIP_FAR_HI
    SBC clip_z1+1
    BPL @clip_p0

    ; Both outside → reject
    SEC
    RTS

@swap_and_clip:
    JSR clip_swap

@clip_p0:
    ; P0 outside far, P1 inside
    ; N = z0 - Z_FAR_BOUND (positive since z0 > plane)
    LDA clip_z0
    SEC
    SBC #CLIP_FAR_LO
    STA clip_n
    LDA clip_z0+1
    SBC #CLIP_FAR_HI
    STA clip_n+1

    ; D = z0 - z1 (positive since z0 > z1)
    LDA clip_z0
    SEC
    SBC clip_z1
    STA clip_d
    LDA clip_z0+1
    SBC clip_z1+1
    STA clip_d+1

    JSR div_16_8

    ; Lerp X
    LDX #0
    JSR lerp_coord
    ; Lerp Y
    LDX #2
    JSR lerp_coord

    ; Set z0 = Z_FAR_BOUND
    LDA #CLIP_FAR_LO
    STA clip_z0
    LDA #CLIP_FAR_HI
    STA clip_z0+1

    CLC
    RTS

; =====================================================================
; div_16_8 — 16-bit restoring binary division → 0.8 quotient
; =====================================================================
; Inputs:  clip_n (16-bit numerator), clip_d (16-bit denominator)
;          Requires 0 < N < D
; Output:  clip_q = floor(N*256/D) (8-bit, 0.8 format)
; Clobbers: A, X, Y
;
; Standard restoring long division producing one quotient bit per
; iteration, with clip_n doubling as the shifting remainder:
;
;   q = 0
;   for _ in range(8):
;       n <<= 1                     # 16-bit shift
;       if n >= d: n -= d; bit = 1  # trial subtract commits
;       else:      bit = 0          # trial subtract discarded
;       q = (q << 1) | bit
;   return q                        # floor(N*256/D), since N < D
;
; The trial subtraction runs in Y (lo) / A (hi) and is only stored
; back on no-borrow; the borrow flag itself is the quotient bit,
; rolled into clip_q via the SEC/CLC + ROL at @shift.  Note the
; shifted remainder must fit in 16 bits, i.e. D <= $7FFF — true for
; all plane/coordinate spans here.

div_16_8:
    LDA #0
    STA clip_q
    LDX #8
@loop:
    ASL clip_n
    ROL clip_n+1
    LDA clip_n
    SEC
    SBC clip_d
    TAY
    LDA clip_n+1
    SBC clip_d+1
    BCC @no_sub
    STA clip_n+1
    STY clip_n              ; commit subtraction
    SEC
    BCS @shift
@no_sub:
    CLC
@shift:
    ROL clip_q
    DEX
    BNE @loop
    RTS

; =====================================================================
; lerp_coord — Interpolate one coordinate of endpoint 0
; =====================================================================
; Input:  X = offset from clip_x0 (0=X, 2=Y, 4=Z)
;         clip_q = t (0.8 quotient)
; Output: clip_x0+X modified (coord0 += t * (coord1 - coord0))
; Clobbers: A, Y, math_a, math_b, math_res, clip_n, clip_n+1, clip_out
;
; The signed 16-bit delta is reduced to sign + magnitude so the
; correction can be built from two UNSIGNED 8x8 muls, then re-signed:
;
;   delta = coord1 - coord0             # 16-bit signed
;   s, d  = sign(delta), abs(delta)
;   corr  = t*d_hi + (t*d_lo >> 8)      # = (t * d) >> 8, 16-bit
;   coord0 += corr if s >= 0 else -corr
;
; t < 1 (0.8 fraction), so corr <= d and coord0 never overshoots
; coord1; truncation of the low product byte rounds |corr| down,
; i.e. the clipped point lands fractionally short of the plane on
; the interpolated axes (the driven axis is set exactly by the
; caller afterwards).

lerp_coord:
    ; delta = coord1 - coord0
    LDA clip_x0+6,X        ; coord1 lo
    SEC
    SBC clip_x0,X           ; - coord0 lo
    STA clip_n              ; delta lo
    LDA clip_x0+7,X        ; coord1 hi
    SBC clip_x0+1,X        ; - coord0 hi
    STA clip_n+1            ; delta hi

    ; Take |delta|, save sign
    BPL @delta_pos
    LDA #0
    SEC
    SBC clip_n
    STA clip_n
    LDA #0
    SBC clip_n+1
    STA clip_n+1
    LDA #$80
    JMP @save_sign
@delta_pos:
    LDA #0
@save_sign:
    STA clip_out

    ; Save coordinate offset
    TXA
    PHA

    ; correction = umul8x8(t, |delta_hi|) + hi(umul8x8(t, |delta_lo|))
    ; Step 1: hi(t * |delta_lo|)
    LDA clip_n              ; |delta_lo|
    STA math_b
    LDA clip_q
    JSR umul8x8             ; A = hi(t * |delta_lo|)
    PHA                     ; save hi byte on stack

    ; Step 2: t * |delta_hi| (full 16-bit)
    LDA clip_n+1            ; |delta_hi|
    STA math_b
    LDA clip_q
    JSR umul8x8             ; A = hi(t * |delta_hi|)

    ; correction = result + stacked hi byte
    TAX                     ; save hi in X
    PLA                     ; hi(t * |delta_lo|)
    CLC
    ADC math_res_lo
    STA clip_n              ; correction lo
    TXA
    ADC #0
    STA clip_n+1            ; correction hi

    ; Negate correction if delta was negative
    LDA clip_out
    BPL @apply
    LDA #0
    SEC
    SBC clip_n
    STA clip_n
    LDA #0
    SBC clip_n+1
    STA clip_n+1

@apply:
    ; coord0 += correction
    PLA
    TAX
    LDA clip_x0,X
    CLC
    ADC clip_n
    STA clip_x0,X
    LDA clip_x0+1,X
    ADC clip_n+1
    STA clip_x0+1,X
    RTS

; =====================================================================
; project_coord — Project one coordinate: offset = hi(umul(lo,recip)) + smul(hi,recip)
; =====================================================================
; Input:  A = coord_lo, X = coord_hi, clip_n = recip
; Output: clip_d:clip_d+1 = signed offset, C pending from lo add
; Clobbers: A, X, math_a, math_b, math_res
;
; Computes offset = (coord * recip) >> 8 for a signed 16-bit coord and
; unsigned 8-bit recip, split into two 8x8 muls by place value:
;   coord * recip = coord_hi*recip*256 + coord_lo*recip
;   offset        = smul(coord_hi, recip)          # signed weight
;                 + (umul(coord_lo, recip) >> 8)   # lo byte unsigned
; The low byte of a two's-complement value carries no sign of its own,
; so only the hi-byte product needs smul8x8.
;
; The carry from the final low-byte ADC is deliberately NOT resolved
; here: it is left pending for clamp_add, whose first instruction is
; ADC #0 on the offset high byte.  The two routines form one sequence.
;
; Pseudocode:
;   lo_hi  = (coord_lo * recip) >> 8     # umul8x8
;   s      = coord_hi * recip            # smul8x8, 16-bit signed
;   offset = (s >> 8) << 8 | ((s & $FF) + lo_hi)   # carry → clamp_add

project_coord:
    STX nmos_tmp            ; save coord_hi
    ; A = coord_lo (first arg to umul8x8)
    LDX clip_n
    STX math_b
    JSR umul8x8             ; A = hi(lo * recip)
    LDX nmos_tmp            ; restore coord_hi
    PHA                     ; save hi(lo * recip)
    TXA                     ; A = coord_hi (first arg to smul8x8)
    ; math_b still = clip_n
    JSR smul8x8             ; A = offset_hi
    STA clip_d+1
    PLA
    CLC
    ADC math_res_lo         ; + lo(smul), carry pending
    STA clip_d
    RTS

; =====================================================================
; clamp_add — Clamp (center + signed_offset) to [0, max]
; =====================================================================
; Input:  A=center, X=max, clip_d=offset_lo, clip_d+1=offset_hi,
;         C=carry pending from caller's ADC
; Output: A=clamped value
; Clobbers: X, clip_out
;
; First folds project_coord's pending carry into the offset high byte,
; then classifies the offset by that byte:
;   hi == $00        small positive: r = center + offset_lo,
;                      clamped to max (both on 8-bit overflow and on
;                      r > max)
;   hi == $FF        small negative: r = center + offset_lo (two's-
;                      complement low byte); carry out means r >= 0,
;                      otherwise clamp to 0
;   otherwise        |offset| >= 256, off screen: the BMI (sign of
;                      hi+1 from the CMP #$FF) sends $01..$7E to max
;                      and $7F..$FE to 0
;
; Pseudocode:
;   hi = offset_hi + pending_carry
;   if hi == 0:
;       r = center + offset_lo
;       return max if r > 255 or r > max else r
;   if hi == $FF:
;       r = center + offset_lo - 256
;       return r if r >= 0 else 0
;   return max if hi > 0 else 0

clamp_add:
    STA clip_out            ; save center
    LDA clip_d+1
    ADC #0                  ; propagate carry from caller
    BEQ @ca_pos
    CMP #$FF
    BEQ @ca_neg
    BMI @ca_zero
@ca_max:
    TXA                     ; large positive or overflow → max
    RTS
@ca_pos:
    LDA clip_d
    CLC
    ADC clip_out            ; + center
    BCS @ca_max             ; overflow → max
    STA clip_out            ; save result
    TXA
    CMP clip_out            ; max - result
    BCC @ca_ret             ; max < result → return max (A=max)
    LDA clip_out            ; max >= result → return result
@ca_ret:
    RTS
@ca_neg:
    LDA clip_d
    CLC
    ADC clip_out            ; + center
    BCS @ca_done            ; carry → valid (result >= 0)
@ca_zero:
    LDA #0
@ca_done:
    RTS

; =====================================================================
; project_and_draw — Project both clip endpoints and draw line
; =====================================================================
; Inputs:  clip_x0..clip_z1 (clipped 3D endpoints in camera space)
;          clip_color = line colour (right-pixel mask format)
; Outputs: line drawn into the back buffer, endpoint pixel included;
;          clip_proj_sx/sy = P0's screen position (read by the caller
;          for intersection-point handling); obj bbox via update_bb
; Assumes: Z values are positive (caller must ensure)
; Clobbers: A, X, Y, math workspace, clip scratch
;
; Perspective projection: screen = centre + (coord * recip) >> 8 with
; recip = recip8(z) = floor(32768/z), i.e. offset = coord * 128 / z.
; Centres: X → 64 (mid-screen), Y → 16.  clamp_add pins the result to
; the screen, so extreme offsets become edge-of-screen endpoints
; rather than wild addresses (only Y needs this in principle — X is
; bounded by the left/right clip planes — but both go through it).
;
; init_base must run while P0's coords are in raster_x0/y0, and recip8
; (inside compute_recip_z2 for P1) clobbers Y — hence the PHA/PLA
; parking of the sub-row around P1's projection.
;
; Pseudocode:
;   for P in (P0, P1):
;       recip = compute_recip_z2(P.z)              # 32768/z
;       P.sx = clamp(64 + (P.x * recip) >> 8, 0, 127)
;       P.sy = clamp(16 + (P.y * recip) >> 8, 0, 159)
;       if P is P0: init_base(); save sub-row Y
;   update_bb(P0.sy); update_bb(P1.sy)             # object dirty bbox
;   draw_line(clip_color)                          # plots [P0, P1)
;   plot_final_pixel(P1.sx)                        # complete segment

project_and_draw:
    ; -- Project P0 --
    LDA clip_z0
    LDX clip_z0+1
    JSR compute_recip_z2

    ; sx0 = clamp(64 + offset_x)
    LDA clip_x0
    LDX clip_x0+1
    JSR project_coord
    ; sx = clamp(64 + offset, 0, 127)
    LDA #64
    LDX #127
    JSR clamp_add
    STA raster_x0
    STA clip_proj_sx

    ; sy0 = clamp(16 + offset_y)
    LDA clip_y0
    LDX clip_y0+1
    JSR project_coord

    ; sy = clamp(16 + offset, 0, 159)
    LDA #16
    LDX #159
    JSR clamp_add
    STA raster_y0
    STA clip_proj_sy

    ; init_base for P0
    JSR init_base
    TYA
    PHA                         ; save sub-row Y (recip8 clobbers Y)

    ; -- Project P1 --
    LDA clip_z1
    LDX clip_z1+1
    JSR compute_recip_z2

    ; sx1
    LDA clip_x1
    LDX clip_x1+1
    JSR project_coord

    LDA #64
    LDX #127
    JSR clamp_add
    STA raster_x1

    ; sy1
    LDA clip_y1
    LDX clip_y1+1
    JSR project_coord

    LDA #16
    LDX #159
    JSR clamp_add
    STA raster_y1

    ; -- Update bounding box from clipped endpoints --
    LDA raster_y0
    JSR update_bb
    LDA raster_y1
    JSR update_bb

    ; -- Draw the line --
    PLA
    TAY                         ; restore sub-row Y from init_base
    LDA clip_color          ; caller-provided colour
    JSR draw_line

    ; -- Plot final pixel at (raster_x1, raster_y1) --
    LDA raster_x1
    JMP plot_final_pixel        ; tail call

; =====================================================================
; plot_final_pixel — Plot a single pixel at (A, raster_base+Y)
; =====================================================================
; Input:  A = x coordinate, Y = sub-row, raster_base set
; Output: pixel written to screen
; Preserves: X, Y
; Clobbers: A
;
; Completes a draw_line chain: draw_line stops one pixel short of the
; endpoint but leaves raster_base/Y addressing it, so only X-parity
; needs deciding here.  Uses the colour masks draw_line derived.
;
; Pseudocode:
;   side = right if x & 1 else left
;   b = screen[base + y]
;   screen[base + y] = (b & clear_mask[side]) | color[side]

plot_final_pixel:
    LSR A                   ; bit 0 → carry (left/right pixel)
    LDA (raster_base),Y
    BCS @pfp_right
    AND #$D5
    ORA raster_color_left
    BCC @pfp_store
@pfp_right:
    AND #$EA
    ORA raster_color_right
@pfp_store:
    STA (raster_base),Y
    RTS

; =====================================================================
; compute_recip_z2 — Compute recip ≈ floor(16384/z) via recip8
; =====================================================================
; Input:  A = z_lo, X = z_hi
; Output: clip_n = floor(32768/z) >> 1 ≈ floor(16384/z)
; Clobbers: A, X, Y, math_b
;
; Thin wrapper marshalling z into recip8's convention (A = z_hi,
; math_b = z_lo) and parking the result in clip_n for project_coord.
; As implemented, recip8's return value floor(32768/z) is stored
; unshifted (the "z2" in the name reads as reciprocal-of-2z:
; 32768/z = 65536/(2z), matching grid.s's RECIP_* constants).
; recip8 returns 0 for z < 256, which cannot occur here: the near
; plane guarantees z >= Z_NEAR_BOUND ($01E0).

compute_recip_z2:
    STA math_b
    TXA
    JSR recip8
    STA clip_n
    RTS
