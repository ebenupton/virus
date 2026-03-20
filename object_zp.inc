; object_zp.inc — Zero-page API for the 3D object renderer
;
; Include-guarded: safe to .include from multiple files.

.ifndef OBJECT_ZP_INC
OBJECT_ZP_INC = 1

.include "zp_layout.inc"

; ── Object API ──────────────────────────────────────────────────────
obj_ptr             = ZP_OBJECT + 0    ; 2 bytes — pointer to object type data
obj_rot_angle       = ZP_OBJECT + 2    ; Y-axis rotation angle (0-255 = full circle)
obj_view_x          = ZP_OBJECT + 3    ; 2 bytes — view-space centre X (lo/hi)
obj_view_y          = ZP_OBJECT + 5    ; 2 bytes — view-space centre Y (lo/hi)
obj_view_z          = ZP_OBJECT + 7    ; 2 bytes — view-space centre Z (lo/hi)
obj_roll_angle      = ZP_OBJECT + 9    ; X-axis pitch angle (0-255 = full circle)
obj_bb_min_sy       = ZP_OBJECT + 10   ; bounding box min screen Y
obj_bb_max_sy       = ZP_OBJECT + 11   ; bounding box max screen Y

; ── Constants ───────────────────────────────────────────────────────
MAX_OBJ_VERTICES    = 10
; Note: enemy has 10 vertices (maximum object)
MAX_OBJ_EDGES       = 24

.endif
