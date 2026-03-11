; object_zp.inc — Zero-page API for the 3D object renderer
;
; Include-guarded: safe to .include from multiple files.
; API surface at $70-$78. Workspace lives in object.s ($80-$8C).

.ifndef OBJECT_ZP_INC
OBJECT_ZP_INC = 1

; ── Object API ──────────────────────────────────────────────────────
obj_ptr             = $70       ; 2 bytes — pointer to object type data
obj_rot_angle       = $72       ; Y-axis rotation angle (0-255 = full circle)
obj_view_x          = $73       ; 2 bytes — view-space centre X (lo/hi)
obj_view_y          = $75       ; 2 bytes — view-space centre Y (lo/hi)
obj_view_z          = $77       ; 2 bytes — view-space centre Z (lo/hi)
obj_roll_angle     = $79       ; X-axis pitch angle (0-255 = full circle)

; ── Bounding box outputs (set by draw_object) ─────────────────────
obj_bb_min_sx       = $12
obj_bb_max_sx       = $13
obj_bb_min_sy       = $14
obj_bb_max_sy       = $15

; ── Constants ───────────────────────────────────────────────────────
MAX_OBJ_VERTICES    = 24
MAX_OBJ_EDGES       = 32

.endif
