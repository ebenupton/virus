; video_zp.inc — Zero-page API for double-buffered video
;
; Include-guarded: safe to .include from multiple files.

.ifndef VIDEO_ZP_INC
VIDEO_ZP_INC = 1

.include "zp_layout.inc"

back_buf_idx    = ZP_VIDEO + 0      ; current back buffer index (0 or 1)
frame_count     = ZP_VIDEO + 1      ; vsync frame counter
dirty_top_buf0  = ZP_VIDEO + 2      ; dirty-top tracking, buffer 0
dirty_top_buf1  = ZP_VIDEO + 3      ; dirty-top tracking, buffer 1
ship_top_buf0   = ZP_VIDEO + 4      ; ship top stripe for buffer 0 (0-19, 20=none)
ship_top_buf1   = ZP_VIDEO + 5      ; ship top stripe for buffer 1
ship_bot_buf0   = ZP_VIDEO + 6      ; ship bottom stripe for buffer 0
ship_bot_buf1   = ZP_VIDEO + 7      ; ship bottom stripe for buffer 1

.endif
