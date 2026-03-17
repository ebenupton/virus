; zp_layout.inc — Zero-page subsystem base addresses
;
; Each subsystem owns contiguous 8-byte-aligned chunks.
; Include-guarded: safe to .include from multiple files.

.ifndef ZP_LAYOUT_INC
ZP_LAYOUT_INC = 1

ZP_SHARED  = $00   ; 1 chunk  (global scratch)
ZP_VIDEO   = $08   ; 1 chunk  (external only)
ZP_GAME    = $10   ; 3 chunks (1 ext + 2 int)
ZP_RASTER  = $28   ; 3 chunks (1 ext + 2 int)
ZP_MATH    = $40   ; 2 chunks (1 ext + 1 int)
ZP_STATUS  = $50   ; 1 chunk  (internal scratch)
ZP_OBJECT  = $58   ; 5 chunks (2 ext + 3 int)
ZP_GRID    = $80   ; 7 chunks (1 ext + 6 int)
ZP_CLIP    = $B8   ; 3 chunks (2 ext + 1 int)
ZP_PARTICLE = $D0  ; 1 chunk  (particle system)
; Total: $D8 used. Free: $D8-$FF (40 bytes)

; ── Shared scratch ────────────────────────────────────────────────────
nmos_tmp        = ZP_SHARED + 0     ; NMOS carry-preserving INC A scratch

.endif
