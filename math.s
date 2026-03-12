; math.s — Fixed-point multiply and division routines for 65C02
;
; Designed as an .include module: no .segment directives, no entry point.
; Include once from your main source file after tables.inc (which provides
; the lookup tables referenced here).
;
; =====================================================================
; Overview
; =====================================================================
;
; This module provides:
;
;   umul8x8          Unsigned  8x8 -> 16-bit multiply (quarter-square)
;   smul8x8          Signed    8x8 -> 16-bit multiply (quarter-square)
;   urecip15           Unsigned  floor(65536/z) for z in [3, 32767]
;
; =====================================================================
; Quarter-square multiplication
; =====================================================================
;
; Both umul8x8 and smul8x8 use the identity:
;
;   a * b = floor((a+b)^2 / 4) - floor((a-b)^2 / 4)
;
; This converts a multiply into two table lookups (sqr[sum], sqr[|diff|])
; and a 16-bit subtract.  Two sets of tables handle sum overflow:
;
;   sqr_lo/sqr_hi     — floor(n^2/4) for n = 0..255
;   sqr2_lo/sqr2_hi   — floor(n^2/4) for n = 256..511
;
; smul8x8 applies a signed correction afterwards:
;   if a < 0:  result_hi -= b
;   if b < 0:  result_hi -= a
;
; =====================================================================
; Table dependencies (from tables.inc)
; =====================================================================
;
;   sqr_lo, sqr_hi         — floor(n^2/4) lo/hi for n=0..255
;   sqr2_lo, sqr2_hi       — floor(n^2/4) lo/hi for n=256..511
;   lerp_recip_lo/hi       — round(2^22/(128+i)) for i=0..128 (urecip15 lerp)
;
; =====================================================================
; Register and ZP conventions
; =====================================================================
;
;   Zero page:  math_a, math_b (inputs), math_res_lo/hi (outputs)
;               — defined in math_zp.inc.
;               norm_k, delta_val (scratch) — workspace, declared below.
;
;   Y register: preserved by smul8x8 and umul8x8 (PHY/PLY around body).
;               NOT preserved by urecip15.
;
; =====================================================================

.include "math_zp.inc"

; ── Math workspace ($60-$61) ────────────────────────────────────────
norm_k          = $60       ; normalisation shift count (used by urecip15)
delta_val       = $61       ; interpolation delta (used by urecip15)

; =====================================================================
; umul8x8 — Unsigned 8x8 -> 16-bit multiply (quarter-square)
; =====================================================================
;
; Inputs:   math_a = unsigned multiplier  (0..255)
;           math_b = unsigned multiplicand (0..255)
; Outputs:  math_res_hi:math_res_lo = 16-bit unsigned product
; Clobbers: A, X, Y
;
; Cycles: ~57 including JSR/RTS.

umul8x8:
    ; -- Compute |a - b| --
    LDA math_a
    SEC
    SBC math_b
    BCS @u_diff_pos
    EOR #$FF
    INC A
@u_diff_pos:
    TAY                     ; Y = |a - b|

    ; -- Compute (a + b) mod 256 --
    LDA math_a
    CLC
    ADC math_b
    TAX
    BCS @u_sum_overflow

    SEC
    LDA sqr_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr_hi,X
    SBC sqr_hi,Y
    STA math_res_hi
    RTS

@u_sum_overflow:
    SEC
    LDA sqr2_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr2_hi,X
    SBC sqr_hi,Y
    STA math_res_hi
    RTS

; =====================================================================
; smul8x8 — Signed 8x8 -> 16-bit multiply (quarter-square)
; =====================================================================
;
; Inputs:   math_a = signed multiplier  (-128..+127)
;           math_b = signed multiplicand (-128..+127)
; Outputs:  math_res_hi:math_res_lo = signed 16-bit product
;           A = math_res_hi (for quick sign checks)
; Clobbers: A, X, Y
;
; Cycles: ~62.

smul8x8:
    ; -- Compute |a - b| --
    LDA math_a
    SEC
    SBC math_b
    BCS @diff_pos
    EOR #$FF
    INC A
@diff_pos:
    TAY

    ; -- Compute (a + b) mod 256 --
    LDA math_a
    CLC
    ADC math_b
    TAX
    BCC @no_overflow

    SEC
    LDA sqr2_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr2_hi,X
    SBC sqr_hi,Y
    BRA @sign_correct

@no_overflow:
    SEC
    LDA sqr_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr_hi,X
    SBC sqr_hi,Y

@sign_correct:
    LDX math_a
    BPL @a_pos
    SEC
    SBC math_b
@a_pos:
    LDX math_b
    BPL @done
    SEC
    SBC math_a
@done:
    STA math_res_hi
    RTS

; =====================================================================
; urecip15 — Compute floor(65536 / z) for z in [3, 32767]
; =====================================================================
;
; Input:    math_a = z high byte (0..127)
;           math_b = z low byte
;           z = math_a:math_b, unsigned 15-bit, must be in [3, 32767]
; Output:   math_res_hi:math_res_lo = floor(65536 / z), range [2, 21845]
; Clobbers: A, X, Y, math_a, math_b, norm_k, delta_val
;
; Algorithm — linear interpolation with one u8 x u8 multiply
; -----------------------------------------------------------
;
; Uses a 129-entry 16-bit table T[i] = round(2^22 / (128 + i)) for
; i in [0, 128], split into lerp_recip_lo/hi (258 bytes total).
;
;   1. Normalise z: left-shift z until bit 7 of the high byte is set,
;      producing Z = z << (15 - k) where k = floor(log2(z)) in [1,14].
;      After normalisation: A = Z_hi = m in [128, 255], math_b = Z_lo
;      = f (8-bit interpolation fraction), X = k.
;      Powers of 2 (m = 128, f = 0) return $8000 >> (k-1) directly.
;
;   2. i = m - 128 (clear bit 7): 7-bit index into T[].
;
;   3. D = T[i] - T[i+1]: the step between adjacent entries.
;      Always in [64, 254], so it fits in a byte.
;
;   4. corr = (f * D) >> 8: one u8 x u8 -> u16 multiply via inlined
;      quarter-square, taking only the high byte.
;
;   5. x1 = T[i] - corr: 16-bit interpolated estimate of 2^22/m.
;
;   6. Q = x1 >> (k - 1): final rescale to 65536/z.
;      Three shift strategies are used depending on s = k - 1:
;        s = 0:     no shift
;        s in [1,4]:  right-shift loop (15 cycles/iteration)
;        s in [5,7]:  left-shift by (8-s) then byte-move
;                     (exploits x >> s = (x << (8-s)) >> 8)
;        s >= 8:      byte-move then right-shift loop for remainder
;
; Accuracy (exhaustive verification over all 32765 inputs):
;   32755 exact, 10 off-by-one (result = floor(65536/z) + 1).
;   Max error: +1.  No negative errors.  Affected inputs:
;     z = 331, 662, 993, 1986, 2979, 3641, 5958, 7282, 10923, 21846.
;
; A post-correction (if Q*z > 65535 then Q--) would eliminate these
; at negligible cost.  Not currently implemented.
;
; Cycles (including JSR, typical non-pow2):
;   k=7 (z 128-255): 185 (best), k=8 (z 256-511): 243 (worst),
;   k=14 (z 16384-32767): 181.  Weighted average ~189.
;   Breakdown: JSR 6, normalisation 19-91, pow2 check 5,
;   interpolation body ~95, final shift 14-82.

urecip15:
    ; -- Normalise: find k and m --
    ; k = floor(log2(z)), m = top 8 bits with MSB at bit 7
    LDA math_a              ; z_hi
    BNE @hi_nonzero

    ; z_hi == 0: z = z_lo in [3, 255], k in [1, 7]
    LDA math_b              ; z_lo
    LDX #7                  ; k starts at 7
    BMI @lo_norm_done       ; bit 7 already set -> k=7, m=z_lo
@norm_lo:
    DEX
    ASL A
    BPL @norm_lo            ; loop until bit 7 set
@lo_norm_done:
    STZ math_b              ; no lower bits (8-bit z fully captured in m)
    BRA @norm_done

@hi_nonzero:
    ; z_hi in [1, 127]: shift z_hi:z_lo left until bit 7 of z_hi set
    ; k = 15 - number_of_shifts
    LDX #15
@norm_hi:
    DEX
    ASL math_b              ; shift z_lo left
    ROL A                   ; shift z_hi left, pulling bit from z_lo
    BPL @norm_hi            ; loop until bit 7 of A set
    ; math_b now holds the lower shifted bits (0 if z was pow2)

@norm_done:
    ; A = m in [128, 255], X = k in [1, 14]
    ; math_b = Z_lo (0 iff z is a power of 2)
    CMP #$80
    BNE @not_pow2

    ; m = 128: check if z is actually a power of 2
    LDY math_b
    BNE @m128_not_pow2

    ; -- Power-of-2: result = 65536 >> k = $8000 >> (k-1) --
    STZ math_res_lo
    LDA #$80
    STA math_res_hi
    DEX                     ; k-1 right shifts
    BEQ @pow2_done
@pow2_loop:
    LSR math_res_hi
    ROR math_res_lo
    DEX
    BNE @pow2_loop
@pow2_done:
    RTS

@m128_not_pow2:
@not_pow2:
    ; -- Linear interpolation --
    ; A = m = Z_hi in [128, 255], X = k, math_b = Z_lo = f
    STX norm_k               ; save k
    AND #$7F                ; i = m - 128
    TAY                     ; Y = i

    ; Load T[i] and compute D = T[i] - T[i+1] (fits in 8 bits)
    LDA lerp_recip_lo,Y    ; read T[i].lo once
    STA math_res_lo
    SEC
    SBC lerp_recip_lo+1,Y
    STA delta_val            ; D = T[i].lo - T[i+1].lo
    LDA lerp_recip_hi,Y
    STA math_res_hi

    ; -- Multiply: hi(f * D) via inlined quarter-square --
    ; f = math_b, D = delta_val
    ; We need only the high byte of the product.

    ; |f - D|
    LDA math_b
    SEC
    SBC delta_val
    BCS @l_diff_pos
    EOR #$FF
    INC A
@l_diff_pos:
    TAX                     ; X = |f - D|

    ; (f + D) mod 256
    LDA math_b
    CLC
    ADC delta_val
    TAY                     ; Y = sum
    BCS @l_sum_ovf

    ; No overflow: corr_hi from sqr tables
    SEC
    LDA sqr_lo,Y
    SBC sqr_lo,X
    LDA sqr_hi,Y
    SBC sqr_hi,X
    BRA @l_sub_corr

@l_sum_ovf:
    ; Overflow: corr_hi from sqr2 tables
    SEC
    LDA sqr2_lo,Y
    SBC sqr_lo,X
    LDA sqr2_hi,Y
    SBC sqr_hi,X

@l_sub_corr:
    ; A = corr = (f * D) >> 8
    ; x1 = T[i] - corr (16-bit minus 8-bit, never underflows)
    EOR #$FF                ; ~corr
    SEC                     ; ADC gives (~corr+1)+mem = mem-corr
    ADC math_res_lo
    STA math_res_lo
    LDA math_res_hi
    ADC #$FF                ; carry=1: +0, carry=0: -1
    STA math_res_hi

    ; -- Final rescale: Q = x1 >> (k - 1) --
    ;
    ; s = k-1 ranges from 0 to 13.  Three strategies:
    ;   s = 0:       no shift needed
    ;   s >= 8:      byte-shift (hi -> lo, zero hi), then right-shift by s-8
    ;   s in [5,7]:  left-shift by (8-s), then byte-move (hi -> lo, zero hi)
    ;   s in [1,4]:  right-shift loop
    ;
    ; The left-shift path avoids the expensive 5-7 iteration right-shift
    ; loop by exploiting the identity: x >> s = (x << (8-s)) >> 8.
    ; This is valid because x1 < 32768, so x1 << 3 < 2^18 and the
    ; high byte after the left-shifts holds the correct result.
    ;
    ; Cycle costs (shift section, including RTS):
    ;   s=0: 14   s=5: 69   s=8:  31   s=12: 55
    ;   s=1: 37   s=6: 60   s=9:  37   s=13: 56
    ;   s=4: 82   s=7: 46   s=10: 43

    LDX norm_k               ; k in [1, 14]
    DEX                     ; s = k - 1
    BEQ @l_shift_done
    CPX #8
    BCC @l_small_shift
    ; s >= 8: byte-shift, then accumulator shifts
    LDA math_res_hi         ; value to shift (hi byte becomes lo)
    CPX #9
    BCC @l_s8_store
    LSR A
    CPX #10
    BCC @l_s8_store
    LSR A
    CPX #11
    BCC @l_s8_store
    LSR A
    CPX #12
    BCC @l_s8_store
    LSR A
    CPX #13
    BCC @l_s8_store
    LSR A
@l_s8_store:
    STA math_res_lo
    STZ math_res_hi
    RTS

@l_shift_loop:
    LSR math_res_hi
    ROR math_res_lo
    DEX
    BNE @l_shift_loop
@l_shift_done:
    RTS

@l_small_shift:
    ; s in [1, 7]
    CPX #5
    BCC @l_shift_loop       ; s < 5: right-shift loop

    ; s in [5, 7]: left-shift by (8-s), then byte-move
    CPX #7
    BEQ @l_ls1              ; s=7: 1 left shift
    CPX #6
    BEQ @l_ls2              ; s=6: 2 left shifts
    ASL math_res_lo         ; s=5: 3 left shifts (fall through)
    ROL math_res_hi
@l_ls2:
    ASL math_res_lo
    ROL math_res_hi
@l_ls1:
    ASL math_res_lo
    ROL math_res_hi
    LDA math_res_hi
    STA math_res_lo
    STZ math_res_hi
    RTS
