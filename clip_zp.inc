; clip_zp.inc — Zero-page API for the 3D line clipper
;
; Include-guarded: safe to .include from multiple files.
; Internal workspace declared in clip.s.

.ifndef CLIP_ZP_INC
CLIP_ZP_INC = 1

.include "zp_layout.inc"

; ── Clipper API ─────────────────────────────────────────────────────
; Camera-space segment endpoints, 16-bit little-endian.  Loaded by the
; caller before the clip_line_* sequence; the plane clippers move the
; outside endpoint onto the plane in place (and may swap P0/P1).
; Layout is contiguous X0,Y0,Z0,X1,Y1,Z1 — clip_swap and lerp_coord
; index across it (coord1 of a pair is always coord0 + 6 bytes).
clip_x0     = ZP_CLIP + 0     ; 2 bytes — endpoint 0 X (8.8 signed)
clip_y0     = ZP_CLIP + 2     ; 2 bytes — endpoint 0 Y (8.8 signed)
clip_z0     = ZP_CLIP + 4     ; 2 bytes — endpoint 0 Z (8.8 signed)
clip_x1     = ZP_CLIP + 6     ; 2 bytes — endpoint 1 X
clip_y1     = ZP_CLIP + 8     ; 2 bytes — endpoint 1 Y
clip_z1     = ZP_CLIP + 10    ; 2 bytes — endpoint 1 Z

; ── Caller-provided colour ────────────────────────────────────────
clip_color  = ZP_CLIP + 12    ; 1 byte  — line colour for project_and_draw

; ── Intersection screen coords (set by project_and_draw) ─────────
clip_proj_sx = ZP_CLIP + 13   ; 1 byte  — projected P0 screen X
clip_proj_sy = ZP_CLIP + 14   ; 1 byte  — projected P0 screen Y

; ── Workspace (written by object.s, used by clip.s routines) ────────
clip_n      = ZP_CLIP + 15    ; 2 bytes — scratch / division numerator

.endif
