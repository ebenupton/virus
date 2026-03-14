; raster_zp.inc — Zero-page API for the line rasterizer
;
; Include-guarded: safe to .include from multiple files.
; External API only. Internal workspace declared in raster.s.

.ifndef RASTER_ZP_INC
RASTER_ZP_INC = 1

.include "zp_layout.inc"

; ── Inputs ───────────────────────────────────────────────────────────
raster_x0           = ZP_RASTER + 0    ; start X  (0..127)
raster_y0           = ZP_RASTER + 1    ; start Y  (0..159)
raster_x1           = ZP_RASTER + 2    ; end X    (0..127)
raster_y1           = ZP_RASTER + 3    ; end Y    (0..159)

; ── Chaining state (set by set_page / draw_line / init_base) ────────
raster_page         = ZP_RASTER + 8    ; screen buffer high byte ($30 or $58)

.endif
