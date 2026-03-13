; clip_zp.inc — Zero-page API for the 3D line clipper
;
; Include-guarded: safe to .include from multiple files.
; API surface at $C0-$D6. Internal workspace lives in clip.s.

.ifndef CLIP_ZP_INC
CLIP_ZP_INC = 1

; ── Clipper API ($C0-$CB) ─────────────────────────────────────────
clip_x0     = $C0       ; 2 bytes — endpoint 0 X (8.8 signed)
clip_y0     = $C2       ; 2 bytes — endpoint 0 Y (8.8 signed)
clip_z0     = $C4       ; 2 bytes — endpoint 0 Z (8.8 signed)
clip_x1     = $C6       ; 2 bytes — endpoint 1 X
clip_y1     = $C8       ; 2 bytes — endpoint 1 Y
clip_z1     = $CA       ; 2 bytes — endpoint 1 Z

; ── Workspace (clobbered by clip_line_left / project_and_draw) ─────
clip_n      = $D0       ; 2 bytes — scratch / division numerator
clip_d      = $D2       ; 2 bytes — scratch / division denominator

; ── Caller-provided colour ────────────────────────────────────────
clip_color  = $D6       ; 1 byte  — line colour for project_and_draw

; ── Intersection screen coords (set by project_and_draw) ─────────
clip_proj_sx = $D7      ; 1 byte  — projected P0 screen X
clip_proj_sy = $D8      ; 1 byte  — projected P0 screen Y

.endif
