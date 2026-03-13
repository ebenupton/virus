; object.s — 3D wireframe object renderer for BBC Micro
;
; Provides: draw_object
; Requires: object_zp.inc, raster_zp.inc, math_zp.inc
; Ext refs: sin_table, cos_table, urecip15, umul8x8, smul8x8,
;           init_base, draw_line, clip_line_left, clip_line_right,
;           clip_line_near, clip_line_far, project_and_draw

.include "object_zp.inc"
.include "raster_zp.inc"
.include "math_zp.inc"
.include "grid_zp.inc"
.include "clip_zp.inc"

; ── Object workspace ($80-$8F) ──────────────────────────────────────
sin_val         = $80       ; precomputed sin(angle) for current frame
cos_val         = $81       ; precomputed cos(angle) for current frame
obj_n_vtx       = $82       ; vertex count (phase 1); temp in phase 2
edge_tab_off    = $83       ; byte offset of edge table in object data
data_off        = $84       ; byte offset into face/edge data
recip           = $85       ; reciprocal (phase 1); edge_id temp (phase 2)

; Scratch registers, reused across phases
scratch0        = $86
scratch1        = $87
scratch2        = $88
scratch3        = $89
scratch4        = $8A
scratch5        = $8B

; Phase 1 (projection) aliases
vtx_idx         = scratch0
local_x         = scratch1
local_y         = scratch2
local_z         = scratch3
vcoord_lo       = scratch4
vcoord_hi       = scratch5

; Phase 2 (backface cull) aliases — overlap with scratch0-5
dx1             = scratch0
dy1             = scratch1
dx2             = scratch2
dy2             = scratch3
cross_lo        = scratch4
cross_hi        = scratch5

; Phase 2 (face iteration) aliases — reuse scratch0-5 AFTER backface test
face_n_edges    = $86       ; edge counter for current face
face_color_val  = $8B       ; face color for clip-boundary edges

; Polygon vertex ring for N-gon clip walk (up to 15 vertices + wraparound copy)
poly_ring       = $60

; Phase 1 (pitch rotation) — reused in phase 2
roll_sin       = $8D       ; precomputed sin(pitch) (phase 1 only)
roll_cos       = $8E       ; precomputed cos(pitch) (phase 1 only)

; Phase 2 (polygon clip walk) — $8C-$8F
poly_vtx_idx    = $8C       ; polygon walk index (0, 1, 2) / outcode temp
clip_isect0_sx  = $8D       ; first intersection screen X
clip_isect0_sy  = $8E       ; first intersection screen Y
clip_has_isect  = $8F       ; flag ($00=none, $FF=have first)

; ── Buffer allocations (BUFFERS segment) ────────────────────────────
.segment "BUFFERS"
obj_proj_sx:    .res MAX_OBJ_VERTICES   ; projected screen X (0..127)
obj_proj_sy:    .res MAX_OBJ_VERTICES   ; projected screen Y (0..159)
obj_edge_drawn: .res 4                   ; 32-bit drawn bitmap
obj_vx_lo:      .res MAX_OBJ_VERTICES   ; view-space X lo
obj_vx_hi:      .res MAX_OBJ_VERTICES   ; view-space X hi
obj_vy_lo:      .res MAX_OBJ_VERTICES   ; view-space Y lo
obj_vy_hi:      .res MAX_OBJ_VERTICES   ; view-space Y hi
obj_vz_lo:      .res MAX_OBJ_VERTICES   ; view-space Z lo
obj_vz_hi:      .res MAX_OBJ_VERTICES   ; view-space Z hi
obj_vtx_clip:   .res MAX_OBJ_VERTICES   ; per-vertex 4-bit outcode
obj_clip_flags: .res 1                   ; object flags byte (bit 7 = skip clip)
.segment "CODE"

; ── Bit mask table for edge bit testing ──
bit_mask_table:
    .byte $01, $02, $04, $08, $10, $20, $40, $80

; ── World positions (8.8 fixed-point), packed for indexed access ──
OBJ_WORLD_PYRAMID = 0
OBJ_WORLD_SHIP    = 6
obj_world_pos:
    ; Pyramid: X=1.0, Y=1.0, Z=0.0
    .byte $00, $01, $00, $01, $00, $00
    ; Ship: X=4.0, Y=31/32, Z=4.0  (on plateau, height 31)
    .byte $00, $04, $F8, $00, $00, $04

; ── Object: Octagonal bipyramid (10 vtx, 24 edges, 16 faces) ──
;
; New data format:
;   Header:   n_vertices, n_edges, flags                (3 bytes)
;             flags bit 7: skip 3D clipping
;   Vertices: n_vertices × (x, y, z)                    (signed bytes)
;   Edges:    n_edges × (v_from, v_to, color)           (3 bytes each)
;   Faces:    n, v_0..v_{n-1}, face_color, eid_0..eid_{n-1} ($FF terminated)
;
; Edge numbering preserved from chain traversal order:
;   e0-e11:  chain 0 (upper star + even base edges)
;   e12-e23: chain 1 (lower star + odd base edges)

obj_pyramid:
    ; Header: n_vertices, n_edges, flags
    .byte 10, 24, $00

    ; Vertices (x, y, z) — signed bytes, object-local coords
    .byte   0,  38,   0            ; v0: top apex
    .byte   0, <(-38),  0          ; v1: bottom apex
    .byte  42,   0,   0            ; v2: base 0°
    .byte  30,   0,  30            ; v3: base 45°
    .byte   0,   0,  42            ; v4: base 90°
    .byte <(-30), 0,  30           ; v5: base 135°
    .byte <(-42), 0,   0           ; v6: base 180°
    .byte <(-30), 0, <(-30)        ; v7: base 225°
    .byte   0,   0, <(-42)         ; v8: base 270°
    .byte  30,   0, <(-30)         ; v9: base 315°

    ; Edge table: 24 edges × (v_from, v_to, color)
    ; e0-e11: chain 0 order (upper star + even base edges)
    .byte 0,2,$01                   ; e0:  v0→v2  (red)
    .byte 2,3,$01                   ; e1:  v2→v3  (red)
    .byte 3,0,$11                   ; e2:  v3→v0  (magenta)
    .byte 0,4,$01                   ; e3:  v0→v4  (red)
    .byte 4,5,$01                   ; e4:  v4→v5  (red)
    .byte 5,0,$11                   ; e5:  v5→v0  (magenta)
    .byte 0,6,$01                   ; e6:  v0→v6  (red)
    .byte 6,7,$01                   ; e7:  v6→v7  (red)
    .byte 7,0,$11                   ; e8:  v7→v0  (magenta)
    .byte 0,8,$01                   ; e9:  v0→v8  (red)
    .byte 8,9,$01                   ; e10: v8→v9  (red)
    .byte 9,0,$11                   ; e11: v9→v0  (magenta)
    ; e12-e23: chain 1 order (lower star + odd base edges)
    .byte 1,2,$01                   ; e12: v1→v2  (red)
    .byte 2,9,$11                   ; e13: v2→v9  (magenta)
    .byte 9,1,$11                   ; e14: v9→v1  (magenta)
    .byte 1,8,$01                   ; e15: v1→v8  (red)
    .byte 8,7,$11                   ; e16: v8→v7  (magenta)
    .byte 7,1,$11                   ; e17: v7→v1  (magenta)
    .byte 1,6,$01                   ; e18: v1→v6  (red)
    .byte 6,5,$11                   ; e19: v6→v5  (magenta)
    .byte 5,1,$11                   ; e20: v5→v1  (magenta)
    .byte 1,4,$01                   ; e21: v1→v4  (red)
    .byte 4,3,$11                   ; e22: v4→v3  (magenta)
    .byte 3,1,$11                   ; e23: v3→v1  (magenta)

    ; Faces: n, v_0..v_{n-1}, face_color, eid_0..eid_{n-1}
    ; Upper faces (v0, base[k], base[k+1])
    .byte 3, 0, 2, 3,  $01,  0,  1,  2    ; F0:  v0-v2-v3
    .byte 3, 0, 3, 4,  $01,  2, 22,  3    ; F1:  v0-v3-v4
    .byte 3, 0, 4, 5,  $01,  3,  4,  5    ; F2:  v0-v4-v5
    .byte 3, 0, 5, 6,  $01,  5, 19,  6    ; F3:  v0-v5-v6
    .byte 3, 0, 6, 7,  $01,  6,  7,  8    ; F4:  v0-v6-v7
    .byte 3, 0, 7, 8,  $01,  8, 16,  9    ; F5:  v0-v7-v8
    .byte 3, 0, 8, 9,  $01,  9, 10, 11    ; F6:  v0-v8-v9
    .byte 3, 0, 9, 2,  $01, 11, 13,  0    ; F7:  v0-v9-v2
    ; Lower faces (v1, base[k+1], base[k] — reversed winding)
    .byte 3, 1, 3, 2,  $01, 23,  1, 12    ; F8:  v1-v3-v2
    .byte 3, 1, 4, 3,  $01, 21, 22, 23    ; F9:  v1-v4-v3
    .byte 3, 1, 5, 4,  $01, 20,  4, 21    ; F10: v1-v5-v4
    .byte 3, 1, 6, 5,  $01, 18, 19, 20    ; F11: v1-v6-v5
    .byte 3, 1, 7, 6,  $01, 17,  7, 18    ; F12: v1-v7-v6
    .byte 3, 1, 8, 7,  $01, 15, 16, 17    ; F13: v1-v8-v7
    .byte 3, 1, 9, 8,  $01, 14, 10, 15    ; F14: v1-v9-v8
    .byte 3, 1, 2, 9,  $01, 12, 13, 14    ; F15: v1-v2-v9
    .byte $FF                              ; sentinel

; ── Object: Player ship (6 vtx, 12 edges, 8 faces) ──
;
; Flat trapezoidal body (v0-v3) with two raised rear fins (v4-v5).
; Based on Zarch lander_model_ship, scaled ×35, Y negated.

obj_ship:
    ; Header: n_vertices, n_edges, flags (bit 7 = no clip)
    .byte 6, 9, $80

    ; Vertices (x, y, z) — signed bytes, halved
    .byte <(-28),   0, <(-24)      ; v0: rear left
    .byte  28,      0, <(-24)      ; v1: rear right
    .byte  14,      0,  24         ; v2: front right
    .byte <(-14),   0,  24         ; v3: front left
    .byte <(-10),  18, <(-24)      ; v4: left fin top
    .byte  10,     18, <(-24)      ; v5: right fin top

    ; Edge table: 9 edges × (v_from, v_to, color)
    .byte 0,1,$15                   ; e0:  rear base (white)
    .byte 1,2,$15                   ; e1:  right body
    .byte 2,3,$15                   ; e2:  front
    .byte 3,0,$15                   ; e3:  left body
    .byte 4,5,$15                   ; e4:  fin ridge (white)
    .byte 0,4,$15                   ; e5:  left fin
    .byte 1,5,$15                   ; e6:  right fin
    .byte 4,3,$15                   ; e7:  upper left
    .byte 5,2,$15                   ; e8:  upper right

    ; Faces: n, v_0..v_{n-1}, face_color, eid_0..eid_{n-1}
    ; Vertex rings reversed vs original to fix Y-negation winding inversion
    .byte 4, 0,3,2,1,  $11,  3,2,1,0      ; F0: bottom quad
    .byte 4, 4,5,2,3,  $11,  4,8,2,7      ; F1: top quad
    .byte 4, 0,1,5,4,  $01,  0,6,4,5      ; F2: rear quad
    .byte 3, 4,3,0,     $11,  7,3,5       ; F3: left triangle
    .byte 3, 1,2,5,     $01,  1,8,6       ; F4: right triangle
    .byte $FF                              ; sentinel

; ── Object: Tree (single triangle, 60° rotated so flat edge faces camera) ──
; =====================================================================
; setup_obj_view — Compute view-space coords from packed world position
; =====================================================================
;
; Input:  Y = offset into obj_world_pos (OBJ_WORLD_PYRAMID)
; Output: obj_view_x/y/z set
;         On return: N set if view_z < 0 (behind camera)
;                    N clear, Z set if view_z == 0 (at camera)
;                    N clear, Z clear if view_z > 0 (visible)

setup_obj_view:
    LDA obj_world_pos+0,Y
    SEC
    SBC cam_x_lo
    STA obj_view_x
    LDA obj_world_pos+1,Y
    SBC cam_x_hi
    STA obj_view_x+1

    LDA #CAM_HEIGHT_LO
    SEC
    SBC obj_world_pos+2,Y
    STA obj_view_y
    LDA #CAM_HEIGHT_HI
    SBC obj_world_pos+3,Y
    STA obj_view_y+1

    LDA obj_world_pos+4,Y
    SEC
    SBC cam_z_lo
    STA obj_view_z
    LDA obj_world_pos+5,Y
    SBC cam_z_hi
    STA obj_view_z+1
    BMI @skip
    ORA obj_view_z
    BEQ @skip
    CLC                     ; C=0: visible
    RTS
@skip:
    SEC                     ; C=1: behind or at camera
    RTS

; =====================================================================
; draw_object — Project and render a 3D wireframe object
; =====================================================================
;
; Inputs:
;   obj_ptr       = pointer to object type data
;   obj_view_x/y/z = view-space centre (set by caller)
;   obj_rot_angle = Y-axis rotation angle
;   obj_roll_angle = X-axis pitch angle

draw_object:
    ; ── Phase 1: Transform & project vertices ──
    ; Precompute sin/cos for Y-axis rotation
    LDX obj_rot_angle
    JSR sincos
    STA sin_val
    STX cos_val

    ; Precompute sin/cos for X-axis roll
    LDX obj_roll_angle
    JSR sincos
    STA roll_sin
    STX roll_cos

    LDY #0
    LDA (obj_ptr),Y
    STA obj_n_vtx               ; vertex count from header
    LDY #2
    LDA (obj_ptr),Y
    STA obj_clip_flags          ; flags (bit 7 = skip clip)

    ; Init bounding box to empty (group zero-stores)
    LDA #0
    STA obj_bb_max_sx
    STA obj_bb_max_sy
    STA vtx_idx              ; vtx_idx = 0
    LDA #127
    STA obj_bb_min_sx
    LDA #160
    STA obj_bb_min_sy

    ; Clear per-vertex outcode array (A clobbered, reload 0 not needed)
    LDX #MAX_OBJ_VERTICES-1
    LDA #0
@clear_clip:
    STA obj_vtx_clip,X
    DEX
    BPL @clear_clip

@proj_loop:
    LDA vtx_idx
    CMP obj_n_vtx
    BCC @proj_vtx
    JMP @proj_done

@proj_vtx:
    ; Y offset = 3 + vtx_idx * 3
    ASL A                       ; vtx_idx*2, C=0 (vtx_idx<128)
    ADC vtx_idx             ; vtx_idx*3, max 69, C=0
    ADC #3
    TAY

    ; Load signed local coords
    LDA (obj_ptr),Y
    STA local_x
    INY
    LDA (obj_ptr),Y
    STA local_y
    INY
    LDA (obj_ptr),Y
    STA local_z

    ; Rotate (local_y, local_z) around X axis (roll), then (local_x, local_z) around Y (yaw)
    JSR rotate_x                ; roll: transforms local_y and local_z in-place
    JSR rotate_y                ; yaw: transforms local_x and local_z in-place

    ; -- view_z = obj_view_z + sign_extend(local_z) --
    LDX #obj_view_z
    LDA local_z
    JSR sign_ext_add

    ; Store view_z in buffers
    LDX vtx_idx
    LDA vcoord_lo
    STA obj_vz_lo,X
    LDA vcoord_hi
    STA obj_vz_hi,X

    ; Skip vertex if vz <= 0 (N flag set from LDA vcoord_hi)
    BPL @vz_ok
    JMP @vtx_clamp
@vz_ok:
    ORA vcoord_lo
    BNE @vz_nz
    JMP @vtx_clamp
@vz_nz:

    ; recip = urecip15(vz << 1)
    LDA vcoord_lo
    ASL A
    STA math_b
    LDA vcoord_hi
    ROL A
    STA math_a
    JSR urecip15
    LDA math_res_lo
    STA clip_n

    ; -- view_x = obj_view_x + sign_extend(local_x) --
    LDX #obj_view_x
    LDA local_x
    JSR sign_ext_add

    ; Store view_x
    LDX vtx_idx
    LDA vcoord_lo
    STA obj_vx_lo,X
    LDA vcoord_hi
    STA obj_vx_hi,X

    ; Compute 4-bit outcode (left/right/near/far) unless no-clip
    BIT obj_clip_flags          ; bit 7 = skip clip
    BMI :+
    JSR compute_outcode         ; X preserved, uses obj_vx/vz buffers
:
    ; offset_x = hi16(view_x * recip)
    LDA vcoord_lo
    LDX vcoord_hi
    JSR project_coord
    ; sx = clamp(64 + offset, 0, 127)
    LDA #64
    LDX #127
    JSR clamp_add
    LDX vtx_idx
    STA obj_proj_sx,X
    LDX #0
    JSR update_bb

    ; -- view_y = obj_view_y - sign_extend(local_y) --
    LDX #obj_view_y
    LDA local_y
    JSR sign_ext_sub

    ; Store view_y in buffers
    LDX vtx_idx
    LDA vcoord_lo
    STA obj_vy_lo,X
    LDA vcoord_hi
    STA obj_vy_hi,X

    ; offset_y = hi16(view_y * recip)
    LDA vcoord_lo
    LDX vcoord_hi
    JSR project_coord
    ; sy = clamp(16 + offset, 0, 159)
    LDA #16
    LDX #159
    JSR clamp_add
    LDX vtx_idx
    STA obj_proj_sy,X
    LDX #2
    JSR update_bb

    INC vtx_idx
    JMP @proj_loop

@vtx_clamp:
    ; Vertex behind camera: store view-space coords, clamp screen position

    ; view_x = obj_view_x + sign_extend(local_x)
    LDX #obj_view_x
    LDA local_x
    JSR sign_ext_add
    LDX vtx_idx
    LDA vcoord_lo
    STA obj_vx_lo,X
    LDA vcoord_hi
    STA obj_vx_hi,X

    ; Compute 4-bit outcode (vx and vz already in buffers) unless no-clip
    BIT obj_clip_flags
    BMI :+
    JSR compute_outcode
:

    ; view_y = obj_view_y - sign_extend(local_y)
    LDX #obj_view_y
    LDA local_y
    JSR sign_ext_sub
    LDX vtx_idx
    LDA vcoord_lo
    STA obj_vy_lo,X
    LDA vcoord_hi
    STA obj_vy_hi,X

    ; Clamped screen coords
    LDA #64
    STA obj_proj_sx,X
    STX nmos_tmp
    LDX #0
    JSR update_bb
    LDX nmos_tmp
    LDA #80
    STA obj_proj_sy,X
    LDX #2
    JSR update_bb
    INC vtx_idx
    JMP @proj_loop

; ── Phase 2: Face-oriented draw ─────────────────────────────────────
@proj_done:
    ; Clear edge-drawn bitmap
    LDA #0
    STA obj_edge_drawn
    STA obj_edge_drawn+1
    STA obj_edge_drawn+2
    STA obj_edge_drawn+3

    ; Compute edge_tab_off = 3 + n_vtx * 3
    LDY #0
    LDA (obj_ptr),Y             ; n_vertices
    STA obj_n_vtx               ; temp
    ASL A                       ; n_vtx*2, C=0 (n_vtx<128)
    ADC obj_n_vtx               ; n_vtx*3, max 72, C=0
    ADC #3
    STA edge_tab_off

    ; Compute face data offset = edge_tab_off + n_edges * 3
    LDY #1
    LDA (obj_ptr),Y             ; n_edges
    STA obj_n_vtx               ; temp
    ASL A                       ; n_edges*2, C=0 (n_edges<128)
    ADC obj_n_vtx               ; n_edges*3, max 96, C=0
    ADC edge_tab_off
    STA data_off

; ── Face iteration loop ──
@face_loop:
    LDY data_off
    LDA (obj_ptr),Y
    CMP #$FF
    BNE @face_ok
    RTS                         ; all faces processed
@face_ok:

    ; Read N-gon face: n, v_0..v_{n-1}, face_color
    ; Vertices stored in poly_ring (safe during backface test)
    ; face_color in $8F, n pushed on stack
    STA face_n_edges            ; n → $86 (for read loop; clobbered by backface)

    ; Read n vertices into poly_ring
    LDX #0
@read_vtx:
    INY
    LDA (obj_ptr),Y
    STA poly_ring,X
    INX
    CPX face_n_edges
    BCC @read_vtx

    ; Wraparound: poly_ring[n] = poly_ring[0]
    LDA poly_ring
    STA poly_ring,X

    ; Read face_color
    INY
    LDA (obj_ptr),Y
    STA clip_has_isect          ; face_color → $8F (temp)

    ; Push n, advance to first edge ID
    LDA face_n_edges
    PHA
    INY
    STY data_off

    ; Set up backface test from first 3 vertices
    LDX poly_ring               ; v_a = poly_ring[0]
    LDA poly_ring+1
    STA dx2                     ; v_b → $88
    LDA poly_ring+2
    STA dy2                     ; v_c → $89

    ; ── Backface test ──
    ; dx1 = sx[v_b] - sx[v_a]   (X = v_a)
    LDY dx2                     ; v_b
    LDA obj_proj_sx,Y
    SEC
    SBC obj_proj_sx,X
    STA dx1

    ; dy1 = (sy[v_b] - sy[v_a]) >> 1 (arithmetic shift right)
    LDA obj_proj_sy,Y
    SEC
    SBC obj_proj_sy,X
    STA dy1
    CMP #$80                    ; C = sign bit (A still = value)
    ROR dy1                     ; ASR → dy1

    ; dx2 = sx[v_c] - sx[v_a]
    LDY dy2                     ; v_c
    LDA obj_proj_sx,Y
    SEC
    SBC obj_proj_sx,X
    STA dx2

    ; dy2 = (sy[v_c] - sy[v_a]) >> 1
    LDA obj_proj_sy,Y
    SEC
    SBC obj_proj_sy,X
    STA dy2
    CMP #$80                    ; C = sign bit (A still = value)
    ROR dy2                     ; ASR → dy2

    ; cross = dx1*dy2 - dy1*dx2
    ; Term 1: smul8x8(dx1, dy2)
    LDA dx1
    STA math_a
    LDA dy2
    STA math_b
    JSR smul8x8
    LDA math_res_lo
    STA cross_lo
    LDA math_res_hi
    STA cross_hi

    ; Term 2: smul8x8(dy1, dx2)
    LDA dy1
    STA math_a
    LDA dx2
    STA math_b
    JSR smul8x8

    ; cross = term1 - term2
    LDA cross_lo
    SEC
    SBC math_res_lo
    LDA cross_hi
    SBC math_res_hi
    ; A = cross_hi; front-facing when cross < 0
    BPL @skip_face

    ; ── Front-facing: restore face data from temps ──
    PLA                         ; n from stack
    STA face_n_edges            ; → $86
    LDA clip_has_isect          ; face_color from $8F
    STA face_color_val          ; → $8B

    ; ── Draw all edges (clipping disabled) ──
    JMP @all_inside

@skip_face:
    ; Back-facing: clean stack and advance past edge IDs
    PLA                         ; n_face_edges
    CLC
    ADC data_off
    STA data_off
    JMP @face_loop

; ── ALL INSIDE: draw each edge with dedup ──
@all_inside:
@ai_edge_loop:
    LDY data_off
    LDA (obj_ptr),Y             ; edge_id
    INY
    STY data_off
    JSR draw_edge_dedup
    DEC face_n_edges
    BNE @ai_edge_loop
    JMP @face_loop

; ── MIXED: polygon clip walk ──
@mixed_clip:
    LDA #0
    STA clip_has_isect          ; no intersections yet
    STA poly_vtx_idx            ; start at polygon edge 0

@poly_edge_loop:
    ; Read edge_id from face data
    LDY data_off
    LDA (obj_ptr),Y             ; edge_id
    STA recip                   ; edge_id → $85
    INY
    STY data_off

    ; Check clip status of poly_v0
    LDX poly_vtx_idx
    LDA poly_ring,X            ; poly_v0 vertex index
    TAX
    LDA obj_vtx_clip,X         ; outcode
    BNE @pe_v0_out

    ; v0 inside — check v1
    LDX poly_vtx_idx
    LDA poly_ring+1,X          ; poly_v1 vertex index
    TAX
    LDA obj_vtx_clip,X
    BNE @pe_straddle

    ; Both inside → draw with dedup
    LDA recip                   ; edge_id
    JSR draw_edge_dedup
    JMP @poly_next

@pe_v0_out:
    ; v0 outside — check v1
    LDX poly_vtx_idx
    LDA poly_ring+1,X          ; poly_v1 vertex index
    TAX
    LDA obj_vtx_clip,X
    BEQ @pe_straddle

    ; Both outside → mark edge as drawn (prevent redundant clip attempts)
    JSR check_and_mark_edge
    JMP @poly_next

@pe_straddle:
    ; One inside, one outside — mark edge drawn
    JSR check_and_mark_edge

    ; Load P0 = poly_v0 3D coords → clip API
    LDX poly_vtx_idx
    LDA poly_ring,X            ; poly_v0 vertex index
    TAX
    LDA obj_vx_lo,X
    STA clip_x0
    LDA obj_vx_hi,X
    STA clip_x0+1
    LDA obj_vy_lo,X
    STA clip_y0
    LDA obj_vy_hi,X
    STA clip_y0+1
    LDA obj_vz_lo,X
    STA clip_z0
    LDA obj_vz_hi,X
    STA clip_z0+1

    ; Load P1 = poly_v1 3D coords → clip API
    LDX poly_vtx_idx
    LDA poly_ring+1,X          ; poly_v1 vertex index
    TAX
    LDA obj_vx_lo,X
    STA clip_x1
    LDA obj_vx_hi,X
    STA clip_x1+1
    LDA obj_vy_lo,X
    STA clip_y1
    LDA obj_vy_hi,X
    STA clip_y1+1
    LDA obj_vz_lo,X
    STA clip_z1
    LDA obj_vz_hi,X
    STA clip_z1+1

    ; Sequential 4-plane clip
    JSR clip_line_left
    BCS @pe_clip_reject
    JSR clip_line_right
    BCS @pe_clip_reject
    JSR clip_line_near
    BCS @pe_clip_reject
    JSR clip_line_far
    BCS @pe_clip_reject

    ; Look up edge color from table
    LDA recip                   ; edge_id (0..23, preserved across clip calls)
    ASL A                       ; eid * 2 (C=0, eid<128)
    ADC recip                   ; eid * 3 (C=0, max 69)
    ADC #2                      ; + 2 → color byte offset (C=0)
    ADC edge_tab_off            ; absolute offset in object data
    TAY
    LDA (obj_ptr),Y             ; edge color
    STA clip_color

    JSR project_and_draw

    ; Handle intersection point (clip_proj_sx/sy set by project_and_draw)
    LDA clip_has_isect
    BNE @pe_second_isect

    ; First intersection: save screen coords
    LDA clip_proj_sx
    STA clip_isect0_sx
    LDA clip_proj_sy
    STA clip_isect0_sy
    LDA #$FF
    STA clip_has_isect
    JMP @poly_next

@pe_clip_reject:
    ; Clip rejected — no visible segment, skip intersection tracking
    BCS @poly_next

@pe_second_isect:
    ; Second intersection: draw clip-boundary edge (face_color)
    LDA clip_isect0_sx
    STA raster_x0
    LDA clip_isect0_sy
    STA raster_y0
    JSR init_base

    LDA clip_proj_sx
    STA raster_x1
    LDA clip_proj_sy
    STA raster_y1
    LDA face_color_val          ; face color for clip boundary
    JSR draw_line

    ; Plot final pixel of clip-boundary edge
    LDA raster_x1
    JSR plot_final_pixel

@poly_next:
    INC poly_vtx_idx
    LDA poly_vtx_idx
    CMP face_n_edges            ; = 3 for triangular faces
    BCS @poly_done
    JMP @poly_edge_loop
@poly_done:
    JMP @face_loop

; =====================================================================
; compute_outcode — Compute 4-bit clip outcode for a vertex
; =====================================================================
; Input:  X = vertex index (obj_vx_lo/hi and obj_vz_lo/hi already stored)
; Output: A = outcode byte, stored in obj_vtx_clip,X
;         Bits: 0=left, 1=right, 2=near, 3=far
; Preserves: X
; Clobbers: A, Y

compute_outcode:
    LDY #0                     ; outcode accumulator in Y

    ; Left: outside if x + HALF_GRID_X < 0
    LDA obj_vx_lo,X
    CLC
    ADC #HALF_GRID_X_LO
    LDA obj_vx_hi,X
    ADC #HALF_GRID_X_HI
    BPL @no_left
    INY                        ; set bit 0
@no_left:

    ; Right: outside if HALF_GRID_X - x < 0
    LDA #HALF_GRID_X_LO
    SEC
    SBC obj_vx_lo,X
    LDA #HALF_GRID_X_HI
    SBC obj_vx_hi,X
    BPL @no_right
    TYA
    ORA #$02
    TAY
@no_right:

    ; Near: outside if z - Z_NEAR_BOUND < 0
    LDA obj_vz_lo,X
    SEC
    SBC #CLIP_NEAR_LO
    LDA obj_vz_hi,X
    SBC #CLIP_NEAR_HI
    BPL @no_near
    TYA
    ORA #$04
    TAY
@no_near:

    ; Far: outside if Z_FAR_BOUND - z < 0
    LDA #CLIP_FAR_LO
    SEC
    SBC obj_vz_lo,X
    LDA #CLIP_FAR_HI
    SBC obj_vz_hi,X
    BPL @no_far
    TYA
    ORA #$08
    TAY
@no_far:

    TYA
    STA obj_vtx_clip,X
    RTS

; =====================================================================
; draw_edge_dedup — Draw an edge if not already drawn, then mark drawn
; =====================================================================
; Input:  A = edge_id
;         edge_tab_off ($83) set
; Output: edge drawn (or skipped if already drawn)
; Clobbers: A, X, Y, obj_n_vtx ($82), recip ($85), raster regs

draw_edge_dedup:
    STA recip                   ; save edge_id → $85
    JSR check_and_mark_edge
    BCS @ded_skip               ; already drawn

    ; Look up edge in table: offset = edge_tab_off + eid * 3
    LDA recip                   ; edge_id (0..23)
    ASL A                       ; eid * 2 (C=0, eid<128)
    ADC recip                   ; eid * 3 (C=0, max 69)
    ADC edge_tab_off            ; absolute offset
    TAY
    LDA (obj_ptr),Y             ; v_from
    TAX                         ; X = v_from
    INY
    LDA (obj_ptr),Y             ; v_to
    STA recip                   ; save v_to → $85
    INY
    LDA (obj_ptr),Y             ; color
    PHA                         ; save color on stack

    ; init_base from v_from
    LDA obj_proj_sx,X
    STA raster_x0
    LDA obj_proj_sy,X
    STA raster_y0
    JSR init_base               ; Y = sub-row

    ; Set up endpoint from v_to
    LDX recip                   ; v_to
    LDA obj_proj_sx,X
    STA raster_x1
    LDA obj_proj_sy,X
    STA raster_y1

    ; Draw (Y preserved from init_base)
    PLA                         ; color
    JSR draw_line

    ; Plot final pixel at (raster_x1, raster_y1)
    LDA raster_x1
    JMP plot_final_pixel        ; tail call

@ded_skip:
    RTS

; =====================================================================
; check_and_mark_edge — Check dedup bitmap, mark if not already drawn
; =====================================================================
; Input:  recip ($85) = edge_id
; Output: C=1 if already drawn (skip), C=0 if newly marked
; Clobbers: A, X, Y

check_and_mark_edge:
    LDA recip
    AND #$07
    TAY
    LDA recip
    LSR A
    LSR A
    LSR A
    TAX
    LDA obj_edge_drawn,X
    AND bit_mask_table,Y
    BNE @cam_already
    LDA bit_mask_table,Y
    ORA obj_edge_drawn,X
    STA obj_edge_drawn,X
    CLC
    RTS
@cam_already:
    SEC
    RTS

; =====================================================================
; rotate_y — Rotate (local_x, local_z) around Y axis by obj_rot_angle
; =====================================================================
; Inputs:  local_x (signed), local_z (signed)
;          sin_val, cos_val precomputed
; Outputs: local_x = (cos*lx + sin*lz) >> 7
;          local_z = (cos*lz - sin*lx) >> 7
; Trashes: math_a, math_b, math_res_lo/hi, A, X, Y
;          Uses stack for intermediate 16-bit value, vcoord_lo/hi as scratch

rotate_y:
    ; ── 1. sin * lx → push 16-bit result ──
    LDA sin_val
    STA math_a
    LDA local_x
    STA math_b
    JSR smul8x8
    ; Result: A = res_hi, math_res_lo = res_lo
    PHA                         ; push sin*lx hi
    LDA math_res_lo
    PHA                         ; push sin*lx lo

    ; ── 2. cos * lx → save in vcoord_lo/hi ──
    LDA cos_val
    STA math_a
    ; math_b still = local_x from call 1
    JSR smul8x8
    LDA math_res_lo
    STA vcoord_lo               ; cos*lx lo
    LDA math_res_hi
    STA vcoord_hi               ; cos*lx hi

    ; ── 3. sin * lz → add to cos*lx, shift >>7 → lx' ──
    LDA sin_val
    STA math_a
    LDA local_z
    STA math_b
    JSR smul8x8
    ; lx' = (cos*lx + sin*lz) >> 7
    LDA vcoord_lo               ; cos*lx lo
    CLC
    ADC math_res_lo             ; + sin*lz lo
    STA vcoord_lo
    LDA vcoord_hi               ; cos*lx hi
    ADC math_res_hi             ; + sin*lz hi
    ; Shift 16-bit (vcoord_lo:A) left by 1, take high byte = >>7
    ASL vcoord_lo
    ROL A
    STA local_x                 ; lx'

    ; ── 4. cos * lz → subtract stacked sin*lx, shift >>7 → lz' ──
    LDA cos_val
    STA math_a
    ; math_b still = local_z from call 3
    JSR smul8x8
    ; lz' = (cos*lz - sin*lx) >> 7
    ; Pull sin*lx from stack (lo first, then hi)
    PLA                         ; sin*lx lo
    STA vcoord_lo
    PLA                         ; sin*lx hi
    STA vcoord_hi
    LDA math_res_lo
    SEC
    SBC vcoord_lo               ; cos*lz lo - sin*lx lo
    STA vcoord_lo
    LDA math_res_hi
    SBC vcoord_hi               ; cos*lz hi - sin*lx hi
    ; Shift 16-bit (vcoord_lo:A) left by 1, take high byte = >>7
    ASL vcoord_lo
    ROL A
    STA local_z                 ; lz'
    RTS

; =====================================================================
; rotate_x — Rotate (local_y, local_z) around X axis by obj_roll_angle
; =====================================================================
; Inputs:  local_y (signed), local_z (signed)
;          roll_sin, roll_cos precomputed
; Outputs: local_y = (cos*ly - sin*lz) >> 7
;          local_z = (sin*ly + cos*lz) >> 7
; Trashes: math_a, math_b, math_res_lo/hi, A, X, Y
;          Uses stack for intermediate 16-bit value, vcoord_lo/hi as scratch

rotate_x:
    ; ── 1. sin * ly → push 16-bit result ──
    LDA roll_sin
    STA math_a
    LDA local_y
    STA math_b
    JSR smul8x8
    PHA                         ; push sin*ly hi
    LDA math_res_lo
    PHA                         ; push sin*ly lo

    ; ── 2. cos * ly → save in vcoord_lo/hi ──
    LDA roll_cos
    STA math_a
    ; math_b still = local_y from call 1
    JSR smul8x8
    LDA math_res_lo
    STA vcoord_lo               ; cos*ly lo
    LDA math_res_hi
    STA vcoord_hi               ; cos*ly hi

    ; ── 3. sin * lz → subtract from cos*ly, shift >>7 → ly' ──
    LDA roll_sin
    STA math_a
    LDA local_z
    STA math_b
    JSR smul8x8
    ; ly' = (cos*ly - sin*lz) >> 7
    LDA vcoord_lo               ; cos*ly lo
    SEC
    SBC math_res_lo             ; - sin*lz lo
    STA vcoord_lo
    LDA vcoord_hi               ; cos*ly hi
    SBC math_res_hi             ; - sin*lz hi
    ASL vcoord_lo
    ROL A
    STA local_y                 ; ly'

    ; ── 4. cos * lz → add stacked sin*ly, shift >>7 → lz' ──
    LDA roll_cos
    STA math_a
    ; math_b still = local_z from call 3
    JSR smul8x8
    ; lz' = (cos*lz + sin*ly) >> 7
    PLA                         ; sin*ly lo
    STA vcoord_lo
    PLA                         ; sin*ly hi
    STA vcoord_hi
    LDA math_res_lo
    CLC
    ADC vcoord_lo               ; cos*lz lo + sin*ly lo
    STA vcoord_lo
    LDA math_res_hi
    ADC vcoord_hi               ; cos*lz hi + sin*ly hi
    ASL vcoord_lo
    ROL A
    STA local_z                 ; lz'
    RTS

; =====================================================================
; sign_ext_sub — Subtract sign-extended A from 16-bit ZP value at X
; =====================================================================
; Input:  A = signed byte, X = ZP address of base
; Output: vcoord_lo:vcoord_hi = base - sign_ext(A)
; Note:   Falls through to sign_ext_add after negating A.
;         Safe for |A| <= 127 (A=$80 wraps).

sign_ext_sub:
    EOR #$FF
    CLC
    ADC #1                      ; A = -A, N flag set correctly
    ; fall through to sign_ext_add

; =====================================================================
; sign_ext_add — Add sign-extended A to 16-bit ZP value at X
; =====================================================================
; Input:  A = signed byte (N flag must reflect A), X = ZP address of base
; Output: vcoord_lo:vcoord_hi = base + sign_ext(A)
; Clobbers: A
; Preserves: X, Y

sign_ext_add:
    CLC
    BPL @pos
    ADC $00,X
    STA vcoord_lo
    LDA $01,X
    ADC #$FF
    JMP @done
@pos:
    ADC $00,X
    STA vcoord_lo
    LDA $01,X
    ADC #0
@done:
    STA vcoord_hi
    RTS

; =====================================================================
; update_bb — Update bounding box min/max pair
; =====================================================================
; Input:  A = value, X = offset (0 = sx, 2 = sy)
; Output: obj_bb_min/max updated
; Preserves: A, Y

update_bb:
    CMP obj_bb_min_sx,X
    BCS :+
    STA obj_bb_min_sx,X
:   CMP obj_bb_max_sx,X
    BCC :+
    STA obj_bb_max_sx,X
:   RTS
