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
; lerp_t, h_to, h_from defined in game.s (forward declarations for bilinear_height)

; ── Buffer allocations (BUFFERS segment) ────────────────────────────
.segment "GRIDBUF"
v_buf:        .res GRID_VTX_Z * ROW_STRIDE     ; row-major, 3 bytes/vertex (sx, sy, v_color)
.segment "CODE"

; Row offset lookup (avoids ×44 multiply)
v_row_offset_lo:
    .byte <(0*ROW_STRIDE), <(1*ROW_STRIDE), <(2*ROW_STRIDE)
    .byte <(3*ROW_STRIDE), <(4*ROW_STRIDE), <(5*ROW_STRIDE)
    .byte <(6*ROW_STRIDE)
.include "edge_color.inc"

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
;
; ── Architecture ─────────────────────────────────────────────────────
; Inputs:  ship_pos (grid tracks the ship; Z_GRID_CENTER puts the
;          centre one cell ahead of it), cam_y_lo/hi (camera height),
;          height_map (32×32 toroidal, [h:5][colour:3] per cell)
; Outputs: terrain drawn (XOR) into the back buffer; grid_min_sy =
;          topmost touched scan line (dirty-rect seed for main_loop);
;          v_buf filled with projected vertices
; Clobbers: whole ZP_GRID window, math regs, raster state
;
; Precisely: recip_val = floor(32768/z_cam) with z_cam in 8.8, i.e.
; ≈ 128/z in world units — the focal length is 128px against a 64px
; half-screen. Screen-x per 0.25-unit cell = recip/4 px = step (8.8).
;
; The mesh is (n_cols × n_rows) vertices; interior vertices lie on
; heightmap cell corners, but the outermost columns and the near/far
; rows are clamped to fixed camera-relative positions (±7/8 unit in X,
; Z_NEAR_BOUND/Z_FAR_BOUND in Z) so the silhouette doesn't swim as the
; ship moves; their heights are interpolated between the two straddled
; cell corners (interp_offset_* are the /64 lerp fractions). When the
; ship sits exactly on a cell-centre line, the clamped edge coincides
; with a real corner and one column/row is dropped (n_cols/n_rows).
;
; Horizontal chains (constant-Z lines) are drawn inline as each row of
; vertices is projected; vertical chains (constant-X) need both rows,
; so vertices are parked in v_buf (sx, sy, v_color) and the v-chains
; are drawn in a second pass, column by column. A chain link whose
; colour resolves to 0 (black) is skipped — the raster base is simply
; re-seeded at the far endpoint.
;
; Pipeline (pseudocode):
;   sub_x/base_x, sub_z/base_z ← ship_pos      # cell + /64 fraction
;   interp offsets, n_cols/n_rows, run_factor  # per-frame constants
;   z_cam = Z_NEAR_BOUND - sub-cell bias       # depth of row 0, 8.8
;   hmap_ptr = &height_map[base_z][0]
;   row 0 (near):  recip = RECIP_NEAR (const), Z-interp toward row 1
;   rows 1..n-2:   recip = recip8(z_cam), on-corner (no Z interp)
;   row n-1 (far): recip = RECIP_FAR (const), Z-interp toward row n-2
;       each row: do_row_body() → project vertices + inline h-chains,
;                 z_cam += $40, rotate hmap_ptr → next row
;   for col in n_cols-1 .. 0:                  # second pass
;       draw v-chain down v_buf (stride ROW_STRIDE)

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
    LDA ship_pos+0   ; x lo
    TAX
    AND #$3F
    STA sub_x
    TXA
    CLC
    ADC #<($20 - HALF_COLS * $40)         ; + $20
    STA scratch_0
    LDA ship_pos+1   ; x hi
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
    LDA ship_pos+4   ; z lo
    TAX
    AND #$3F
    STA sub_z
    TXA
    CLC
    ADC #<($20 - (HALF_ROWS - 1) * $40)  ; + $A0
    TAX                                    ; save biased lo
    STA scratch_0
    LDA ship_pos+5   ; z hi
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

    ; The clamped near/far rows sit at fixed camera depths, so their
    ; reciprocals are assembly-time constants (= floor(32768/z), same
    ; scale recip8 returns); only interior rows pay for a recip8 call.
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
@v_seg_tail:
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
    JMP @v_seg_tail


; =====================================================================
; height_to_sy — Convert h*8 to screen-y via multiply + cam_y offset
; =====================================================================
; Input:  A = h*8 (0..248), math_b = recip_val
; Output: A = screen-y (clamped ≥ 0)
; Clobbers: A, X, Y, seg_count, math_res
;
; Perspective-projects a vertex height at the current row's depth:
;   sy = (cam_y - h) * recip / 256      # h in old-scale lo units (h*8)
; with the horizon (sy for cam_y == h) at screen row 0.
;
; Only the low bytes are multiplied: (cam_y_lo - h*8) is an 8-bit
; unsigned subtraction that may wrap; add_cam_y_offset then adds
; recip once per cam_y_hi count and corrects the wrap, which together
; reconstruct the exact 16-bit (cam_y - h*8) * recip / 256.

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
;
;   sy = A + cam_y_hi * recip          # small loop, cam_y_hi is 1..2
;   if cam_y_lo < h*8: sy -= recip     # lo-byte multiply had wrapped
;   clamp: overflow → 255 (below screen), underflow → 0 (above)
; The rasteriser clips to the real screen, so 0/255 are just "far
; off-screen" sentinels that keep the line endpoints sane.

add_cam_y_offset:
    CLC
    ADC #0                    ; horizon at top of screen
    LDX cam_y_hi
    BEQ @aco_borrow
@aco_loop:
    CLC
    ADC recip_val
    BCS @aco_clamp            ; overflow → off-screen below
    DEX
    BNE @aco_loop
@aco_borrow:
    LDX cam_y_lo
    CPX seg_count             ; was cam_y_lo >= h*8?
    BCS @aco_done             ; no borrow → done
    SEC
    SBC recip_val             ; correct for 256-wrap
    BCS @aco_done
    LDA #0                    ; underflow → clamp to 0
@aco_done:
    RTS
@aco_clamp:
    LDA #$FF                  ; overflow → clamp to 255 (rasteriser clips to screen)
    RTS

; =====================================================================
; lut_lookup — Look up interpolation LUT value
; =====================================================================
; Input:  A = diff_h8 (8..248, multiple of 8), C = 1 (from caller's SBC)
; Output: A = LUT value (pre-scaled delta)
; Note:   diff > 12 reads beyond table — acceptable approximation
;
; interp_lut (see gen_interp.py) is diff-major, 16 entries per diff:
;   lut[(diff-1)*16 + lerp_t/4] = round((lerp_t/4*4 + 2) * diff / 8)
; i.e. delta ≈ diff_h8 * lerp_t / 64, with lerp_t quantised to 4s and
; bin-centred. Index = (diff_h8 - 8) << 1 | (lerp_t >> 2).

lut_lookup:
    AND #$F8                  ; round diff to multiple of 8 (prevents LUT overflow)
    BEQ @ll_done              ; diff < 8 → delta = 0
    SBC #8                    ; (diff-1)×8 (C=1 from caller, AND preserves C)
    ASL A                     ; (diff-1) << 4
    STA h_to
    LDA lerp_t
    LSR A
    LSR A                     ; offset = lerp_t/4 (0..15)
    ORA h_to                  ; (diff-1)<<4 | offset
    TAX
    LDA interp_lut,X
@ll_done:
    RTS

; =====================================================================
; lerp_height — Interpolate from h_a towards h_b by offset
; =====================================================================
; Input:  A = h_a×8 (0..248), h_to = h_b×8 (0..248), lerp_t = offset (0..63)
; Output: A = interpolated height h×8 (0..248)
; Clobbers: h_from, h_to, X
;
;   return h_a + (h_b - h_a) * lerp_t / 64        # LUT-quantised
; Split by direction so the LUT only ever sees a positive diff:
; h_a > h_b subtracts the delta, h_b > h_a adds it, equal is free.
; Shared by edge/Z vertex interpolation and by game.s bilinear_height.

lerp_height:
    CMP h_to
    BEQ @lh_done              ; same → A is already h×8
    STA h_from                ; save h_a (h×8)
    BCC @lh_b_higher
    ; h_a > h_b (C=1 from CMP fall-through)
    SBC h_to                  ; diff_h8 (C=1 from CMP, no SEC needed)
    JSR lut_lookup            ; A = delta (C=1 from SBC, no borrow)
    STA h_to
    LDA h_from                ; h_a already h×8
    SEC
    SBC h_to
@lh_done:
    RTS
@lh_b_higher:
    ; h_b > h_a
    LDA h_to
    SEC
    SBC h_from                ; diff_h8 (C=1 after, no borrow)
    JSR lut_lookup            ; A = delta
    CLC
    ADC h_from                ; h_a already h×8
    RTS

; =====================================================================
; compute_interp_offsets — Compute symmetric interpolation pair
; =====================================================================
; Input:  A = sub value (0..63)
; Output: X = |sub - 32|, A = 64 - |sub - 32|
; Clobbers: none besides A, X
;
; The clamped edge vertex sits half a cell ($20/64) away from the
; ship's sub-cell position, so its lerp fraction from the straddled
; corner is |sub - 32|; the opposite edge gets the complement (the two
; always sum to 64). X == 0 (sub == 32, edge exactly on a corner) is
; the caller's cue to drop a column/row.

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
;
; Input:  X = z_interp_offset (non-zero), hmap_col, vtx_cell
; Output: A = interpolated h×8 (via lerp_height tail call)
;
;   return lerp(outer_h8, height_map[inner_row][col] & $F8, X/64)
; Used for every vertex of the clamped near/far rows, whose true Z
; lies between two heightmap rows.

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
;
; For a clamped left/right edge vertex: its true X lies between the
; outer column (already in vtx_cell, Z-interpolated by
; lookup_and_color if needed) and the inner column.
;
;   h_inner = height_map[row][Y] & $F8
;   if z_interp_offset:                     # corner vertex of a
;       h_inner = lerp(h_inner,             # clamped near/far row →
;                      inner_row[Y], z_off) # full bilinear
;   h = lerp(h_outer, h_inner, A/64)
;   vtx_cell+1 = height_to_sy(h)

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
;
; The per-vertex heightmap fetch — one (hmap_ptr),Y read per vertex:
;   cell = height_map[row][hmap_col]        # [h:5][pattern:3]
;   class = sea (h==0) / plateau (h==31) / land
;   v_color = v_color_<class>[pattern]      # LUTs in edge_color.inc
;   h_color = h_color_<class>[pattern]
;   if z_interp_offset:                     # clamped near/far row
;       h*8 = z_interp_vertex()             # lerp toward inner row
;       if h_color == white ($15):          # plateau outline colour
;           h_color = h_colour of the inner-row cell
;           # h-chains span the Z boundary, so a white edge must be
;           # re-resolved from the cell actually being crossed into
;   return h*8

lookup_and_color:
    LDY hmap_col
    LDA (hmap_ptr),Y
    STA vtx_cell            ; full cell byte for z_interp_vertex
    AND #$07
    TAX                       ; X = color bits (0-7)
    LDA vtx_cell
    AND #$F8                  ; A = h*8
    BEQ @lc_sea
    CMP #$F8
    BEQ @lc_plat
    ; --- normal land (hot path, fall through) ---
    PHA
    LDA v_color_land,X
    STA v_color
    LDA h_color_land,X
    STA h_color
    PLA
@lc_z:
    LDX z_interp_offset
    BEQ @lc_done
    JSR z_interp_vertex       ; A = z-interp h*8
    STA vtx_cell              ; update for edge interp
    ; --- Z colour override: h_color only (h-chains cross Z boundary) ---
    LDA h_color
    CMP #$15
    BNE @lc_z_ret             ; only override white (plateau edge)
    LDY hmap_col
    LDA (interp_z_ptr),Y     ; Z-adjacent cell (inner row, same col)
    JSR resolve_inner_colors  ; h_to = inner_h
    LDA h_to
    STA h_color
@lc_z_ret:
    LDA vtx_cell              ; restore A = z-interp h*8
@lc_done:
    RTS

@lc_sea:
    PHA                       ; save h*8 = 0
    LDA v_color_sea,X
    STA v_color
    LDA h_color_sea,X
    STA h_color
    PLA
    BEQ @lc_z                ; unconditional (A=0)

@lc_plat:
    PHA                       ; save h*8 = $F8
    LDA v_color_plat,X
    STA v_color
    LDA h_color_plat,X
    STA h_color
    PLA
    BNE @lc_z                ; unconditional (A=$F8)

; =====================================================================
; override_edge_color — X-adjacent v_color override for edge vertices
; =====================================================================
; At left/right edge vertices, override v_color only (v-chains cross
; the X boundary; h-chains run along it and keep their colour).
;
; Input:  Y = inner heightmap column (preserved for interp_height)
; Effect: May modify v_color
; Scratch: h_from, h_to
;
; Mirror of the Z override in lookup_and_color: a clamped edge vertex
; is displaced in X, so its v-chain (which crosses the X boundary) may
; have moved into the neighbouring cell. Only white ($15, the plateau
; outline) is re-resolved, from the X-adjacent inner cell:
;   if v_color == white: v_color = inner_v(height_map[row][Y])

override_edge_color:
    LDA v_color
    CMP #$15
    BNE @oec_done             ; only override white (plateau edge)
    LDA (hmap_ptr),Y          ; X-adjacent inner cell
    JSR resolve_inner_colors  ; h_from = inner_v
    LDA h_from
    STA v_color
@oec_done:
    RTS

; =====================================================================
; resolve_inner_colors — Resolve a cell byte into v/h colour indices
; =====================================================================
; Input:  A = heightmap cell byte
; Output: h_from = inner_v, h_to = inner_h
; Preserves: Y
;
; Full class+pattern colour resolution for an arbitrary cell byte
; (the boundary-override path, cf. lookup_and_color's inlined LUTs).
; Exploits the layout of edge_color.inc — the three 8-entry v/h table
; pairs are contiguous, so one index into the sea tables reaches all:
;   index = pattern + {sea: 0, plateau: 16, land: 32}
;   inner_v = v_color_sea[index]; inner_h = h_color_sea[index]

resolve_inner_colors:
    TAX
    AND #$07                  ; color bits (0-7)
    STA h_from                ; temp: colour index
    TXA
    AND #$F8                  ; h*8
    BEQ @ric_lookup           ; sea: index = color_bits + 0
    CMP #$F8
    LDA h_from
    BCS @ric_plat
    ; land: C=0 from CMP (h*8 < $F8)
    ADC #32                   ; land tables at offset 32
    BNE @ric_set              ; always taken (32..39)
@ric_plat:
    ADC #15                   ; C=1: plat tables at offset 16
@ric_set:
    STA h_from
@ric_lookup:
    LDX h_from
    LDA v_color_sea,X         ; inner_v (unified table offset)
    STA h_from                ; inner_v
    LDA h_color_sea,X         ; inner_h
    STA h_to                  ; inner_h
    RTS

; =====================================================================
; do_middle_vertex — Lookup + project middle vertex (entry point 1)
; do_vertex_tail   — Store v_buf + h-chain + advance (entry point 2)
; =====================================================================
; do_middle_vertex: no input needed (reads hmap state)
; do_vertex_tail:   A = sx, vtx_cell+1 = sy, v_color set
;
; do_middle_vertex — the interior-vertex hot path:
;   h*8 = lookup_and_color(); sy = height_to_sy(h*8); sx = run_hi
; (edge vertices instead go through interp_height and computed sx,
; then jump straight into do_vertex_tail).
;
; do_vertex_tail — everything common to emitting one vertex:
;   v_buf[v_off..+2] = (sx, sy, v_color)     # for the v-chain pass
;   grid_min_sy = min(grid_min_sy, sy)       # dirty-top tracking
;   if pending_h_color:                      # h-chain from prev vertex
;       draw_line(prev → this, colour drawn is prev vertex's h_color)
;   else:                                    # first vertex, or black
;       init_base(this)                      # re-seed raster position
;   pending_h_color = h_color                # for the next segment
;   hmap_col = (hmap_col + 1) & 31           # toroidal column walk
;   run += step                              # sx += recip/4 px (8.8)
;
; The raster chains: draw_line leaves raster_base/Y at the endpoint,
; saved in h_chain_sub_y so the next segment continues without a
; fresh init_base.

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
;
;   # Per-row constants from recip (≈128/z px per world unit):
;   step = recip << 6                  # 8.8 px per 0.25-unit cell
;   edge_offset = recip - ceil(recip/8)   # = recip*7/8 px → the
;                                      # clamped edges at x = ∓7/8 unit
;   run = $4000 - K*recip              # sx of leftmost cell corner:
;       # 64px centre minus (camera→column-0 distance K, 8.8) * recip;
;       # K = $100+sub_x or $C0+sub_x depending on which side of the
;       # cell centre the ship sits (run_factor/run_sub_recip encode
;       # the $100 part as an extra whole recip subtraction)
;   hmap_col = base_x; v_off = row base in v_buf; pending_h_color = 0
;   left edge:  lookup, override v_color, X-interp height,
;               sx = 64 - edge_offset            → do_vertex_tail
;   middle:     n_cols-2 × do_middle_vertex (sx from run accumulator)
;   right edge: mirror of left, sx = 64 + edge_offset
;   prev/cur/next hmap row pointers rotate; hmap_row = (row+1) & 31
;   z_cam += $40 (0.25 unit); proj_row += 1

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
    JSR override_edge_color
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
    JSR override_edge_color
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
; One heightmap row = 32 bytes; row 31 → row 0 wraps by stepping the
; hi byte back $0400 (the whole 1K map). hmap_row must already hold
; the *current* row index. Reached by fall-through from do_row_body
; and called once directly for the near row's interp_z_ptr.

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