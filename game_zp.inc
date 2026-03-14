; game_zp.inc — Zero-page API for game/camera state
;
; Include-guarded: safe to .include from multiple files.

.ifndef GAME_ZP_INC
GAME_ZP_INC = 1

.include "zp_layout.inc"

cam_x_lo        = ZP_GAME + 0      ; 8.8 fixed-point X position (low byte)
cam_x_hi        = ZP_GAME + 1      ; 8.8 fixed-point X position (high byte)
cam_z_lo        = ZP_GAME + 2      ; 8.8 fixed-point Z position (low byte)
cam_z_hi        = ZP_GAME + 3      ; 8.8 fixed-point Z position (high byte)
cam_y_lo        = ZP_GAME + 4      ; 8.8 fixed-point Y position (low byte)
cam_y_hi        = ZP_GAME + 5      ; 8.8 fixed-point Y position (high byte)

.endif
