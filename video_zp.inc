; video_zp.inc — Zero-page API for double-buffered video
;
; Include-guarded: safe to .include from multiple files.

.ifndef VIDEO_ZP_INC
VIDEO_ZP_INC = 1

.include "zp_layout.inc"

; Per-buffer state comes in _buf0/_buf1 pairs (indexed by back_buf_idx):
; with double buffering, each buffer's recorded state is two fields old
; when the buffer next becomes the back buffer.
;
; dirty_top_bufN = topmost scan line (0..159) the grid reached when the
; buffer was last drawn; 160 = fully clean.  Set from grid_min_sy at
; end of frame; consumed by clear_screen/clear_ship and the minimap
; redraw check.  ship_top/bot_bufN are in char-row stripes (0..19).

back_buf_idx    = ZP_VIDEO + 0      ; current back buffer index (0 or 1)
frame_count     = ZP_VIDEO + 1      ; vsync frame counter
dirty_top_buf0  = ZP_VIDEO + 2      ; dirty-top tracking, buffer 0
dirty_top_buf1  = ZP_VIDEO + 3      ; dirty-top tracking, buffer 1
ship_top_buf0   = ZP_VIDEO + 4      ; ship top stripe for buffer 0 (0-19, 20=none)
ship_top_buf1   = ZP_VIDEO + 5
ship_bot_buf0   = ZP_VIDEO + 6      ; ship bottom stripe for buffer 0
ship_bot_buf1   = ZP_VIDEO + 7

.endif
