; grid.s — Perspective grid projection and rendering for BBC Micro
;
; TODO: restore a single plot_final_pixel at the end of draw_grid
;       (top-right corner pixel is noticeably missing)
;
; Provides: draw_grid
; Requires: raster_zp.inc, math_zp.inc, grid_zp.inc
; Ext refs: cam_x_lo/hi, cam_z_lo/hi, height_map, recip8, umul8x8,
;           init_base, draw_line

.include "raster_zp.inc"
.include "math_zp.inc"
.include "grid_zp.inc"

; ── Grid internal workspace (ZP_GRID internal) ────────────────────
h_chain_sub_y   = ZP_GRID + 1      ; saved sub_y for inline h-chain drawing
v_off           = ZP_GRID + 2      ; v_buf byte offset (single-byte, max 188)
h_color         = ZP_GRID + 3      ; pre-resolved h_color for current vertex
; Pointers
grid_ptr        = ZP_GRID + 7      ; 1 byte — v_buf offset for v-chain pass
hmap_ptr        = ZP_GRID + 9      ; 2 bytes — heightmap row pointer
next_hmap_ptr   = ZP_GRID + 11     ; 2 bytes — next heightmap row pointer
interp_z_ptr    = ZP_GRID + 13     ; 2 bytes — inner row heightmap pointer for Z interp
prev_hmap_ptr   = ZP_GRID + 15     ; 2 bytes — previous row's hmap_ptr (for far row)
; Z / step / run
z_cam_lo        = ZP_GRID + 19     ; z_cam low byte (8.8 fractional part, running)
z_cam_hi        = ZP_GRID + 20     ; z_cam high byte (8.8 integer part, running)
step_lo         = ZP_GRID + 21     ; x step low byte (recip * 64, fractional)
step_hi         = ZP_GRID + 22     ; x step high byte (recip * 64, integer)
run_lo          = ZP_GRID + 23     ; sx running accumulator low byte
run_hi          = ZP_GRID + 24     ; sx running accumulator high byte
; Per-row state
proj_row        = ZP_GRID + 25     ; outer loop counter (row index)
proj_col        = ZP_GRID + 26     ; inner loop counter (vertices remaining)
recip_val       = ZP_GRID + 27     ; recip for current row (≈ 64/z_cam)
run_factor      = ZP_GRID + 28     ; precomputed sx_running multiply factor
base_x          = ZP_GRID + 29     ; heightmap column base for column 0
base_z          = ZP_GRID + 30     ; heightmap row base for row 0
hmap_col        = ZP_GRID + 31     ; current heightmap column index (0..31)
hmap_row        = ZP_GRID + 32     ; current heightmap row index (0..31)
; Grid dimensions / clamps
n_cols           = ZP_GRID + 33     ; vertices per row this frame
n_rows          = ZP_GRID + 34     ; vertex rows this frame
pending_h_color = ZP_GRID + 36     ; h_color from previous vertex for h-chain
edge_offset     = ZP_GRID + 37     ; hi($E0 * recip), used for edge sx
run_sub_recip   = ZP_GRID + 38     ; flag: subtract recip from run_hi (0 or 1)
; Interpolation
interp_offset_left    = ZP_GRID + 41  ; left-edge interpolation offset (0..63)
interp_offset_right    = ZP_GRID + 42  ; right-edge interpolation offset (0..63)
interp_offset_near = ZP_GRID + 43  ; near-row Z interpolation offset (0..63)
interp_offset_far  = ZP_GRID + 44  ; far-row Z interpolation offset (0..64, 64=skip)
z_interp_offset    = ZP_GRID + 45  ; current row's Z offset (0 = no Z interp)
; Scratch
scratch_0       = ZP_GRID + 46     ; scratch
; ZP_GRID + 47 reserved for scratch_0+1 (implicit 2nd byte)
scratch_1       = ZP_GRID + 48     ; scratch
scratch_2       = ZP_GRID + 49     ; scratch
scratch_3       = ZP_GRID + 50     ; scratch
scratch_4       = ZP_GRID + 51     ; scratch
; Aliases — init
sub_x           = scratch_1        ; ship fractional X within cell
sub_z           = scratch_2        ; ship fractional Z within cell
; Aliases — projection / draw
vtx_cell        = scratch_0        ; cell byte (byte 0), sy (byte +1)
seg_count       = scratch_1        ; segments remaining
saved_y         = scratch_3        ; saved sub-row Y
v_color         = scratch_4        ; pre-resolved v_color for current vertex
; Aliases — interpolation (same ZP, different context)
lerp_t          = scratch_1        ; interpolation offset (0..63)
h_to            = scratch_2        ; target height
h_from          = scratch_3        ; source height

; ── Buffer allocations (BUFFERS segment) ────────────────────────────
.segment "GRIDBUF"
v_buf:        .res GRID_VTX_Z * ROW_STRIDE     ; row-major, 3 bytes/vertex (sx, sy, v_color)
.segment "CODE"

; Row offset lookup (avoids ×44 multiply)
v_row_offset_lo:
    .byte <(0*ROW_STRIDE), <(1*ROW_STRIDE), <(2*ROW_STRIDE)
    .byte <(3*ROW_STRIDE), <(4*ROW_STRIDE), <(5*ROW_STRIDE)
    .byte <(6*ROW_STRIDE)
; Edge colour LUTs: index = (bits2-0 << 1) | sea_flag
; Split tables avoid runtime bit extraction (h=bits 4,2,0; v=bits 5,3,1)
h_color_lut:
    .byte $05,$14,$15,$14,$04,$10,$00,$10,$15,$14,$15,$14,$04,$10,$00,$10
v_color_lut:
    .byte $05,$14,$15,$14,$15,$14,$15,$14,$04,$10,$00,$10,$04,$10,$00,$10

; =====================================================================
; draw_grid — Project grid + draw h-chains inline + draw v-chains
; =====================================================================
;
; Grid: GRID_COLS × GRID_ROWS cells, 0.25-unit spacing, centred on camera.
; Camera: (cam_x, -1.5, cam_z) — cam_y constant, no yaw.
; Projection: vx = 64·x_cam/z_cam, vy = 64·y_cam/z_cam,
;             screen centre (64, 16).
;
; Per-row: one recip8 call gives recip ≈ 64/z_cam.
; Per-vertex sy: combined multiply of (cam_y_lo - h*8) * recip, plus cam_y_hi offset.
; sx advances by a constant step = recip·0.25 per vertex (16-bit add).

; --- Init & z_cam setup ---
; grid_min_sy is set to 160 (off-screen) — tracks the topmost grid pixel
; for dirty-rect purposes.
;
; z_cam is the 8.8 fixed-point distance from camera to the nearest grid
; row (row 0). The grid is centred on the camera, so row 0 is
; HALF_ROWS-1 cells ahead. The EOR/AND trick folds both halves of the
; sub-cell position into a single subtraction.
;
; Then it caches the ship's fractional position within its heightmap
; cell — sub_x and sub_z (0–63 each). These control edge interpolation
; and whether to omit the last column/row.

draw_grid:
    LDA #160
    STA grid_min_sy

    ; --- Combined sub_x + base_x ---
    ; Reading ship_x_lo once: extract sub_x (low 6 bits), then add
    ; K = $20 - HALF_COLS*$40 and extract bits 10:6 for base_x.
    LDA obj_world_pos+OBJ_WORLD_SHIP+0   ; x lo
    TAX
    AND #$3F
    STA sub_x
    TXA
    CLC
    ADC #<($20 - HALF_COLS * $40)         ; + $20
    STA scratch_0
    LDA obj_world_pos+OBJ_WORLD_SHIP+1   ; x hi
    ADC #>($20 - HALF_COLS * $40)         ; + $FF + carry
    ASL scratch_0
    ROL A
    ASL scratch_0
    ROL A
    AND #$1F
    STA base_x

    ; --- Combined sub_z + base_z + z_cam ---
    ; Reading ship_z_lo once: extract sub_z, compute base_z from
    ; bits 10:6, then z_cam from (biased_lo & $3F) = (sub_z ^ $20).
    LDA obj_world_pos+OBJ_WORLD_SHIP+4   ; z lo
    TAX
    AND #$3F
    STA sub_z
    TXA
    CLC
    ADC #<($20 - (HALF_ROWS - 1) * $40)  ; + $A0
    TAX                                    ; save biased lo
    STA scratch_0
    LDA obj_world_pos+OBJ_WORLD_SHIP+5   ; z hi
    ADC #>($20 - (HALF_ROWS - 1) * $40)  ; + $FF + carry
    ASL scratch_0
    ROL A
    ASL scratch_0
    ROL A
    AND #$1F
    STA base_z
    ; z_cam = Z_NEAR_BOUND - (biased_lo & $3F)
    ; lo never borrows ($E0 - max $3F = $A1), so hi is constant
    TXA
    AND #$3F
    STA scratch_0
    SEC
    LDA #<Z_NEAR_BOUND
    SBC scratch_0
    STA z_cam_lo
    LDA #>Z_NEAR_BOUND
    STA z_cam_hi

    ; --- Interpolation offsets + grid dimensions ---
    ; compute_interp_offsets returns X = |sub - 32|, so X == 0 iff
    ; sub == $20 (edge vertices coincide → drop one col/row).
    LDA sub_x
    JSR compute_interp_offsets
    STX interp_offset_left
    STA interp_offset_right
    LDA #GRID_VTX_X - 1
    CPX #1                    ; C = (sub_x != $20)
    ADC #0                    ; n_cols = 8 or 9
    STA n_cols

    LDA sub_z
    JSR compute_interp_offsets
    STX interp_offset_near
    STA interp_offset_far
    LDA #GRID_VTX_Z - 1
    CPX #1                    ; C = (sub_z != $20)
    ADC #0                    ; n_rows = 6 or 7
    STA n_rows

    ; --- Precompute run_factor for sx_running ---
    ; sx_running = $4000 - K*recip, where K depends on sub_x:
    ;   sub_x < $20: K = $100+sub_x → factor=sub_x, sub_recip=1
    ;   sub_x >= $20: K = $C0+sub_x → factor=$C0+sub_x, sub_recip=0
    LDA sub_x
    LDX #1
    CMP #$20
    BCC @rf_done
    LDX #0
    ADC #$BF                  ; + $C0 (C=1 from CMP)
@rf_done:
    STA run_factor
    STX run_sub_recip

    ; --- Initial hmap_ptr from base_z ---
    ; hmap_ptr = height_map + hmap_row * 32
    ; Shift row left 5, with >height_map/4 pre-loaded so ROLs
    ; accumulate both row bits and base address.
    LDA #>height_map / 4
    STA hmap_ptr+1
    LDA base_z
    STA hmap_row
    ASL A
    ASL A
    ASL A
    ASL A
    ROL hmap_ptr+1
    ASL A
    ROL hmap_ptr+1
    STA hmap_ptr

    RECIP_NEAR = 65536 / (Z_NEAR_BOUND * 2)
    RECIP_FAR  = 65536 / (Z_FAR_BOUND * 2)

    ; === Peeled row loop ===
    LDA #1
    STA proj_row

    ; --- Near row (row 0): constant recip, Z-interp toward next row ---
    JSR compute_next_hmap     ; need next_hmap_ptr for interp_z_ptr
    LDA #RECIP_NEAR
    STA recip_val
    LDA interp_offset_near
    STA z_interp_offset       ; store unconditionally (0 = no interp)
    BEQ @near_go              ; skip ptr setup if no Z interp
    LDA next_hmap_ptr
    STA interp_z_ptr
    LDA next_hmap_ptr+1
    STA interp_z_ptr+1
@near_go:
    JSR do_row_body           ; proj_row now 1, hmap advanced

    ; --- Interior rows: table recip, no Z interp ---
    LDA #0
    STA z_interp_offset
@interior:
    LDA z_cam_lo
    STA math_b
    LDA z_cam_hi
    JSR recip8
    STA recip_val
    JSR do_row_body
    LDA proj_row
    CMP n_rows
    BCC @interior             ; loop while proj_row < n_rows

    ; --- Far row (last): constant recip, Z-interp toward prev row ---
    LDA #RECIP_FAR
    STA recip_val
    LDA interp_offset_far
    CMP #64
    BCS @far_go               ; 64 → no Z interp (z_interp_offset still 0)
    STA z_interp_offset
    LDA prev_hmap_ptr
    STA interp_z_ptr
    LDA prev_hmap_ptr+1
    STA interp_z_ptr+1
@far_go:
    JSR do_row_body
    ; --- V-chain drawing ---
    ; After all rows are projected and h-chains drawn inline, v-chains
    ; are drawn column by column. For each column, grid_ptr walks down
    ; v_buf by ROW_STRIDE, reading v_color from +2.

    ; --- Post-projection: draw v-chains column by column ---
    DEC n_rows                ; n_rows → seg count (not needed after this)
    DEC n_cols                ; pre-decrement for loop counter
@v_col_loop:
    ; grid_ptr = n_cols * 3 (v_buf offset; page-aligned so no base add)
    LDA n_cols
    ASL A                     ; C=0 (n_cols ≤ 8, bit 7 clear)
    ADC n_cols                ; A = col * 3
    STA grid_ptr
    TAX

    ; --- Inline v-chain: first vertex init ---
    LDA v_buf,X               ; sx
    STA raster_x0
    LDA v_buf+1,X             ; sy
    STA raster_y0
    JSR init_base             ; Y = sub_y

    LDA n_rows
    STA seg_count
@v_seg:
    STY saved_y
    ; Advance grid_ptr by ROW_STRIDE (no page cross — single page buffer)
    LDA grid_ptr
    CLC
    ADC #ROW_STRIDE
    STA grid_ptr
    TAX
    LDA v_buf,X               ; endpoint sx
    STA raster_x1
    LDA v_buf+1,X             ; endpoint sy
    STA raster_y1
    LDA v_buf+2-ROW_STRIDE,X  ; v_color (start vertex, not endpoint)
    BEQ @v_skip_black
    LDY saved_y
    JSR draw_line
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    DEC seg_count
    BNE @v_seg
    DEC n_cols
    BPL @v_col_loop
    RTS
@v_skip_black:
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    JSR init_base
    DEC seg_count
    BNE @v_seg
    DEC n_cols
    BPL @v_col_loop
    RTS


; =====================================================================
; height_to_sy — Convert h*8 to screen-y via multiply + cam_y offset
; =====================================================================
; Input:  A = h*8 (0..248), math_b = recip_val
; Output: A = screen-y (clamped ≥ 0)
; Clobbers: A, X, Y, seg_count, math_res

height_to_sy:
    STA seg_count             ; save h*8 for borrow check
    LDA cam_y_lo
    SEC
    SBC seg_count             ; A = cam_y_lo - h*8 (unsigned)
    JSR umul8x8               ; A * math_b (= recip_val); A = hi byte
    ; fall through to add_cam_y_offset

; =====================================================================
; add_cam_y_offset — Add cam_y integer part and correct for borrow
; =====================================================================
; Input:  A = hi(combined * recip), seg_count = h*8
; Output: A = screen-y (clamped ≥ 0)

add_cam_y_offset:
    CLC
    ADC #16
    LDX cam_y_hi
    BEQ @aco_borrow
    CLC
    ADC recip_val
    DEX
    BEQ @aco_borrow
    CLC
    ADC recip_val
@aco_borrow:
    LDX cam_y_lo
    CPX seg_count             ; was cam_y_lo >= h*8?
    BCS @aco_done             ; no borrow → done
    SEC
    SBC recip_val             ; correct for 256-wrap
    BCS @aco_done
    LDA #0                    ; clamp to 0
@aco_done:
    RTS

; =====================================================================
; lut_lookup — Look up interpolation LUT value
; =====================================================================
; Input:  A = diff (1..31), lerp_t = offset (0..63)
; Output: A = LUT value (pre-scaled delta)

lut_lookup:
    CMP #5
    BCS @ll_big               ; diff > 4 → multiply path
    SEC
    SBC #1                    ; diff - 1 (0..3)
    STA h_to
    LDA lerp_t
    ASL A
    ASL A                     ; offset * 4
    ORA h_to                  ; + (diff-1)
    TAX
    LDA interp_lut,X
    RTS
@ll_big:
    ; diff > 4: compute diff * offset / 8 via repeated addition
    TAX                       ; X = diff (loop counter)
    LDA #0
    STA h_to                  ; hi byte of accumulator
@ll_add:
    CLC
    ADC lerp_t
    BCC @ll_nc
    INC h_to
@ll_nc:
    DEX
    BNE @ll_add
    ; h_to:A = diff * offset; shift right 3
    LSR h_to
    ROR A
    LSR h_to
    ROR A
    LSR h_to
    ROR A
    RTS

; =====================================================================
; lerp_height — Interpolate from h_a towards h_b by offset
; =====================================================================
; Input:  A = h_a×8 (0..248), h_to = h_b×8 (0..248), lerp_t = offset (0..63)
; Output: A = interpolated height h×8 (0..248)
; Clobbers: h_from, h_to, X

lerp_height:
    CMP h_to
    BEQ @lh_done              ; same → A is already h×8
    STA h_from                ; save h_a (h×8)
    BCC @lh_b_higher
    ; h_a > h_b: result = h_a_h8 − delta_scaled
    SEC
    SBC h_to                  ; diff_h8
    LSR A
    LSR A
    LSR A                     ; diff (1..31)
    JSR lut_lookup            ; A = pre-scaled delta
    STA h_to
    LDA h_from                ; h_a already h×8
    SEC
    SBC h_to
    RTS
@lh_b_higher:
    ; h_b > h_a: result = h_a_h8 + delta_scaled
    LDA h_to
    SEC
    SBC h_from                ; diff_h8
    LSR A
    LSR A
    LSR A                     ; diff (1..31)
    JSR lut_lookup            ; A = pre-scaled delta
    CLC
    ADC h_from                ; h_a already h×8
    RTS
@lh_done:
    RTS

; =====================================================================
; compute_interp_offsets — Compute symmetric interpolation pair
; =====================================================================
; Input:  A = sub value (0..63)
; Output: X = |sub - 32|, A = 64 - |sub - 32|
; Clobbers: none besides A, X

compute_interp_offsets:
    CMP #$20
    BCS @hi
    ADC #32                   ; C=0 from BCS not-taken
    BCC @done
@hi:
    SEC
    SBC #32
@done:
    TAX                       ; X = offset_a
    EOR #$3F
    CLC
    ADC #1                    ; A = 64 - offset_a = offset_b
    RTS

; =====================================================================
; z_interp_vertex — Z-interpolate height in vtx_cell
; =====================================================================
; Interpolates vtx_cell's height (bits 3–7) between outer row (hmap_ptr)
; and inner row (interp_z_ptr) using z_interp_offset.
; Preserves colour bits (0–2) in vtx_cell.

z_interp_vertex:
    STX lerp_t                ; X = z_interp_offset from caller
    LDY hmap_col
    LDA (interp_z_ptr),Y      ; inner row cell byte
    AND #$F8                  ; h_inner_z × 8
    STA h_to
    LDA vtx_cell
    AND #$F8                  ; h_outer_z × 8
    JMP lerp_height            ; tail call — A = h×8 (0..248)

; =====================================================================
; interp_height — Interpolate height between outer and inner cell
; =====================================================================
; Input:  Y = inner heightmap column, A = X interpolation offset (0..63)
; Effect: Recomputes vtx_cell+1 (sy) at interpolated height
; Handles corner-case bilinear interpolation (X + Z)

interp_height:
    PHA                       ; push X offset to stack
    LDA (hmap_ptr),Y          ; inner cell byte at inner column
    AND #$F8                  ; h_inner × 8
    ; Z-interpolate h_inner if on boundary row (corner case)
    LDX z_interp_offset
    BEQ @ih_z_done
    STA h_from                ; save h_inner_outer_row (h×8)
    STX lerp_t                ; Z offset
    LDA (interp_z_ptr),Y      ; inner row at inner column
    AND #$F8                  ; h×8
    STA h_to
    LDA h_from
    JSR lerp_height            ; A = Z-interpolated h×8
    AND #$F8                  ; normalize to multiple of 8
@ih_z_done:
    STA h_to                  ; h_inner h×8 (Z-interpolated if corner)
    ; X-interpolate between h_outer and h_inner
    PLA                       ; recover X offset
    STA lerp_t
    LDA vtx_cell
    AND #$F8                  ; h_outer × 8 (already Z-interpolated)
    CMP h_to
    BEQ @ih_done              ; same height → already h×8
    JSR lerp_height           ; A = interpolated h×8 (0..248)
@ih_done:
    JSR height_to_sy          ; A = sy
    STA vtx_cell+1
    RTS

; =====================================================================
; lookup_and_color — Read heightmap cell, extract h*8/color, Z-interp
; =====================================================================
; Input:  hmap_col, hmap_ptr, z_interp_offset
; Output: A = h*8 (0..248), vtx_cell = cell byte or z-interp h*8,
;         v_color = color LUT index
; Clobbers: X, Y

lookup_and_color:
    LDY hmap_col
    LDA (hmap_ptr),Y
    STA vtx_cell            ; full cell byte for z_interp_vertex
    ASL A
    AND #$0E
    TAX                       ; X = color LUT index (land)
    LDA vtx_cell
    AND #$F8                  ; A = h*8
    BNE @lc_land
    INX                       ; sea flag (odd LUT index)
@lc_land:
    PHA                       ; save h*8
    LDA v_color_lut,X
    STA v_color           ; pre-resolved v_color
    LDA h_color_lut,X
    STA h_color         ; pre-resolved h_color
    PLA                       ; restore h*8
    LDX z_interp_offset
    BEQ @lc_done
    JSR z_interp_vertex       ; A = z-interp h*8
    STA vtx_cell            ; update for edge interp
@lc_done:
    RTS

; =====================================================================
; do_middle_vertex — Lookup + project middle vertex (entry point 1)
; do_vertex_tail   — Store v_buf + h-chain + advance (entry point 2)
; =====================================================================
; do_middle_vertex: no input needed (reads hmap state)
; do_vertex_tail:   A = sx, vtx_cell+1 = sy, v_color set

do_middle_vertex:
    JSR lookup_and_color      ; A = h*8
    JSR height_to_sy          ; A = sy
    STA vtx_cell+1
    LDA run_hi                ; A = sx
    ; fall through to do_vertex_tail

do_vertex_tail:
    ; --- v_buf store ---
    ; A = sx for this vertex
    LDY v_off
    STA raster_x1
    STA v_buf,Y               ; sx at offset 0
    INY
    LDA vtx_cell+1          ; sy
    STA raster_y1
    STA v_buf,Y               ; sy at offset 1
    ; --- dirty tracking while A = sy ---
    CMP grid_min_sy
    BCS @vt_no_dirty
    STA grid_min_sy
@vt_no_dirty:
    INY
    LDA v_color           ; v_color (pre-resolved)
    STA v_buf,Y               ; v_color at offset 2
    INY
    STY v_off                 ; advance past all 3 bytes

    ; --- Inline h-chain drawing ---
    ; pending_h_color = 0 for first vertex (pre-cleared) or black
    ; segments: skip draw, re-init base. Non-zero: draw h-chain.
    LDA pending_h_color
    BEQ @vt_h_skip
    LDY h_chain_sub_y
    JSR draw_line
@vt_h_skip:
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    LDA pending_h_color
    BNE @vt_h_done
    JSR init_base
@vt_h_done:
    STY h_chain_sub_y

    ; --- Update h-chain color for next vertex ---
    LDA h_color
    STA pending_h_color       ; for next vertex's h-chain draw

    ; --- Column advance ---
    LDX hmap_col
    INX
    TXA
    AND #$1F
    STA hmap_col

    LDA run_lo
    CLC
    ADC step_lo
    STA run_lo
    LDA run_hi
    ADC step_hi
    STA run_hi

    RTS

; =====================================================================
; do_row_body — Process one vertex row (step, edges, vertices, advance)
; =====================================================================
; Input:  recip_val, z_interp_offset set by caller
; Effect: Projects all vertices for this row, draws h-chains inline,
;         rotates hmap pointers, advances z_cam and proj_row.
;         Falls through to compute_next_hmap.

do_row_body:
    ; --- Step = recip * 64 (16-bit), the screen-x increment per cell ---
    ; recip << 6 = (recip:$00) >> 2
    LDA recip_val
    LSR A
    STA step_hi
    LDA #0
    ROR A
    LSR step_hi
    ROR A
    STA step_lo

    ; --- edge_offset = floor(recip * 7/8) = recip - ceil(recip/8) ---
    LDA recip_val
    CLC
    ADC #7
    LSR A
    LSR A
    LSR A                     ; ceil(recip/8)
    STA scratch_0
    LDA recip_val
    SEC
    SBC scratch_0
    STA edge_offset

    ; --- sx_running = $4000 - run_factor * recip [- recip*256] ---
    LDA recip_val
    STA math_b
    LDA run_factor
    JSR umul8x8
    LDA #0
    SEC
    SBC math_res_lo
    STA run_lo
    LDA #$40
    SBC math_res_hi
    LDX run_sub_recip
    BEQ @no_sub_recip
    SEC
    SBC recip_val
@no_sub_recip:
    STA run_hi

    ; Reset heightmap column for this row
    LDA base_x
    STA hmap_col

    ; --- Init v_off for this row ---
    LDX proj_row
    LDA v_row_offset_lo-1,X
    STA v_off

    ; --- Pre-clear for first-vertex h-chain ---
    LDA #0
    STA pending_h_color

    ; --- Left edge vertex ---
    JSR lookup_and_color      ; A = h*8, vtx_cell set for interp
    LDY hmap_col
    INY
    TYA
    AND #$1F
    TAY                       ; Y = inner column
    LDA interp_offset_left
    JSR interp_height         ; sets vtx_cell+1
    LDA #64
    SEC
    SBC edge_offset           ; A = sx
    JSR do_vertex_tail

    ; --- Middle vertices ---
    LDA n_cols
    SEC
    SBC #2
    STA proj_col
@mid_loop:
    JSR do_middle_vertex
    DEC proj_col
    BNE @mid_loop

    ; --- Right edge vertex ---
    JSR lookup_and_color      ; A = h*8, vtx_cell set for interp
    LDY hmap_col
    DEY
    TYA
    AND #$1F
    TAY                       ; Y = inner column
    LDA interp_offset_right
    JSR interp_height         ; sets vtx_cell+1
    LDA edge_offset
    CLC
    ADC #64                   ; A = sx
    JSR do_vertex_tail

    ; --- Row tail: rotate hmap, advance z_cam/proj_row ---
    ; Rotate hmap pointers: prev = current, current = next
    LDA hmap_ptr
    STA prev_hmap_ptr
    LDA hmap_ptr+1
    STA prev_hmap_ptr+1
    LDA next_hmap_ptr
    STA hmap_ptr
    LDA next_hmap_ptr+1
    STA hmap_ptr+1
    ; Advance hmap_row (wrapping at 32)
    LDY hmap_row
    INY
    TYA
    AND #$1F
    STA hmap_row

    ; z_cam += 64 ($0040 = 0.25 units in 8.8)
    LDA z_cam_lo
    CLC
    ADC #$40
    STA z_cam_lo
    LDA z_cam_hi
    ADC #0
    STA z_cam_hi

    INC proj_row
    ; fall through to compute_next_hmap

; =====================================================================
; compute_next_hmap — Compute next_hmap_ptr = hmap_ptr + 32 (with wrap)
; =====================================================================

compute_next_hmap:
    CLC
    LDA hmap_ptr
    ADC #32
    STA next_hmap_ptr
    LDA hmap_ptr+1
    ADC #0
    LDY hmap_row
    CPY #31
    BNE @no_wrap
    SEC
    SBC #4                    ; subtract $0400 (1024 bytes = 32 rows)
@no_wrap:
    STA next_hmap_ptr+1
    RTS