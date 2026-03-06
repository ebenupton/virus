; math_zp.inc — Zero-page allocations for math routines
;
; Include-guarded: safe to .include from multiple files.
; All addresses live in $8D-$90, $93, $9B, $AD.
; No overlap with raster_zp.inc ($70-$77, $80-$84).

.ifndef MATH_ZP_INC
MATH_ZP_INC = 1

; ── Multiply workspace ────────────────────────────────────────────────
math_a          = $8D       ; 1 byte — multiplier input (signed or unsigned)
math_b          = $8E       ; 1 byte — multiplicand input (signed or unsigned)
math_res_lo     = $8F       ; result low byte
math_res_hi     = $90       ; result high byte

; ── General temp ──────────────────────────────────────────────────────
temp2           = $93       ; scratch byte (used by urecip15)

; ── Division scratch (used internally by urecip15) ───────────────────
div_tmp1        = $9B       ; scratch byte

.endif
