; math_zp.inc — Zero-page API for math routines
;
; Include-guarded: safe to .include from multiple files.
; API surface at $50-$53. Workspace lives in math.s ($60-$61).

.ifndef MATH_ZP_INC
MATH_ZP_INC = 1

; ── Multiply / divide interface ─────────────────────────────────────
math_a              = $50       ; 1 byte — multiplier input (signed or unsigned)
math_b              = $51       ; 1 byte — multiplicand input (signed or unsigned)
math_res_lo         = $52       ; result low byte
math_res_hi         = $53       ; result high byte

.endif
