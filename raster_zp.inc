; raster_zp.inc — Zero-page API for the line rasterizer
;
; Include-guarded: safe to .include from multiple files.
; API surface at $30-$39. Workspace lives in raster.s ($40-$42).

.ifndef RASTER_ZP_INC
RASTER_ZP_INC = 1

; ── Inputs ───────────────────────────────────────────────────────────
raster_x0           = $30       ; start X  (0..127)
raster_y0           = $31       ; start Y  (0..159)
raster_x1           = $32       ; end X    (0..127)
raster_y1           = $33       ; end Y    (0..159)
raster_page         = $34       ; screen buffer high byte ($30 or $58)

; ── Outputs (chaining state, set by draw_line / init_base) ──────────
raster_base         = $35       ; 2 bytes — screen cell pointer (lo/hi)
raster_color_right  = $37       ; colour in right-pixel format (bits 4,2,0)
raster_color_left   = $38       ; colour in left-pixel format (bits 5,3,1)
raster_color_both   = $39       ; colour with both pixels set (left | right)

.endif
