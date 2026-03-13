; clip.s — Cohen-Sutherland 3D line clipper (4 clip planes)
;
; Provides: clip_line_left, clip_line_right, clip_line_near, clip_line_far,
;           project_and_draw
; Requires: raster_zp.inc, math_zp.inc, grid_zp.inc
;           urecip15, umul8x8, smul8x8, init_base, draw_line

.include "raster_zp.inc"
.include "math_zp.inc"
.include "grid_zp.inc"
.include "clip_zp.inc"

; ── Internal workspace ($D4-$D5, extends clip_zp.inc) ─────────────
clip_q      = $D4       ; 1 byte  — t quotient (0.8)
clip_out    = $D5       ; 1 byte  — sign flag for lerp

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
    LDX #0
@loop:
    LDA clip_x0,X
    LDY clip_x1,X
    STA clip_x1,X
    TYA
    STA clip_x0,X
    INX
    CPX #6
    BCC @loop
    RTS

; =====================================================================
; clip_line_left — Clip line to left plane (x >= -HALF_GRID_X)
; =====================================================================
; Inputs:  clip_x0..clip_z1 set
; Outputs: C=0 accept (endpoints may be modified), C=1 reject
; Clobbers: A, X, Y, clip workspace

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
    LDA clip_q
    STA math_a
    LDA clip_n              ; |delta_lo|
    STA math_b
    JSR umul8x8
    LDA math_res_hi
    PHA                     ; save hi byte on stack

    ; Step 2: t * |delta_hi| (full 16-bit)
    ; math_a still = clip_q (umul8x8 reads but doesn't write math_a)
    LDA clip_n+1            ; |delta_hi|
    STA math_b
    JSR umul8x8

    ; correction = result + stacked hi byte
    PLA
    CLC
    ADC math_res_lo
    STA clip_n              ; correction lo
    LDA math_res_hi
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

project_coord:
    STX nmos_tmp            ; save coord_hi (umul8x8 clobbers X)
    STA math_a
    LDA clip_n
    STA math_b
    JSR umul8x8
    LDA math_res_hi         ; hi(lo * recip)
    LDX nmos_tmp            ; restore coord_hi
    STX math_a
    PHA                     ; save hi(lo * recip)
    ; math_b still = clip_n
    JSR smul8x8
    STA clip_d+1            ; offset_hi
    PLA
    CLC
    ADC math_res_lo         ; + lo(smul), carry pending
    STA clip_d              ; offset_lo
    RTS

; =====================================================================
; clamp_add — Clamp (center + signed_offset) to [0, max]
; =====================================================================
; Input:  A=center, X=max, clip_d=offset_lo, clip_d+1=offset_hi,
;         C=carry pending from caller's ADC
; Output: A=clamped value
; Clobbers: X, clip_out

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
; Assumes: Z values are positive (caller must ensure)
; Clobbers: A, X, Y, math workspace, clip scratch

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

    ; sy0 = clamp(80 + offset_y)
    LDA clip_y0
    LDX clip_y0+1
    JSR project_coord

    ; sy = clamp(80 + offset, 0, 159)
    LDA #80
    LDX #159
    JSR clamp_add
    STA raster_y0
    STA clip_proj_sy

    ; init_base for P0
    JSR init_base
    TYA
    PHA                         ; save sub-row Y (urecip15 clobbers Y)

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

    LDA #80
    LDX #159
    JSR clamp_add
    STA raster_y1

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
; compute_recip_z2 — Compute recip from z << 2 via urecip15
; =====================================================================
; Input:  A = z_lo, X = z_hi
; Output: clip_n = lo(urecip15(z << 2))
; Clobbers: A, X, Y, math_a, math_b, math_res

compute_recip_z2:
    ASL A
    STA math_b
    TXA
    ROL A
    ASL math_b
    ROL A
    STA math_a
    JSR urecip15
    LDA math_res_lo
    STA clip_n
    RTS
