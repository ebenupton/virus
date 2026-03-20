; zp_layout.inc — Zero-page subsystem base addresses
;
; Compact layout. ZP_GRID and ZP_BUFFERS overlap (never active simultaneously).
; Include-guarded: safe to .include from multiple files.

.ifndef ZP_LAYOUT_INC
ZP_LAYOUT_INC = 1

ZP_SHARED   = $00   ; 6 bytes  ($00-$05)
ZP_VIDEO    = $06   ; 8 bytes  ($06-$0D)
ZP_GAME     = $0E   ; 22 bytes ($0E-$23)
ZP_RASTER   = $24   ; 13 bytes ($24-$30)
ZP_MATH     = $31   ; 4 bytes  ($31-$34)
ZP_STATUS   = $35   ; 4 bytes  ($35-$38)
ZP_PARTICLE = $39   ; 4 bytes  ($39-$3C)
ZP_OBJECT   = $3D   ; 38 bytes ($3D-$62)
ZP_CLIP     = $63   ; 21 bytes ($63-$77)
ZP_GRID     = $78   ; 52 bytes ($78-$AB, used during draw_grid)
ZP_BUFFERS  = $78   ; 90 bytes ($78-$D1, used during draw_object)
; Enemy state: $D2-$E7 (22 bytes)
; Free: $E8-$FF (24 bytes)

; ── Shared scratch ────────────────────────────────────────────────────
nmos_tmp        = ZP_SHARED + 0     ; NMOS carry-preserving INC A scratch

.endif
