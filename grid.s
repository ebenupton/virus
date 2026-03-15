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
; Pointers
grid_ptr        = ZP_GRID + 7      ; 2 bytes — v-chain post-pass column ptr
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
n_vtx           = ZP_GRID + 33     ; vertices per row this frame
n_rows          = ZP_GRID + 34     ; vertex rows this frame
n_rows_m1       = ZP_GRID + 35     ; n_rows-1, precomputed for V-chain final pixel check
pending_h_color = ZP_GRID + 36     ; h_color from previous vertex for h-chain
edge_offset     = ZP_GRID + 37     ; hi($E0 * recip), used for edge sx
run_sub_recip   = ZP_GRID + 38     ; flag: subtract recip from run_hi (0 or 1)
; Interpolation
interp_offset_l    = ZP_GRID + 41  ; left-edge interpolation offset (0..63)
interp_offset_r    = ZP_GRID + 42  ; right-edge interpolation offset (0..63)
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
offset_tmp      = scratch_0        ; various temporary uses
seg_count       = scratch_1        ; segments remaining / lerp offset
chain_idx       = scratch_2        ; chain byte offset / lerp h_b
saved_y         = scratch_3        ; saved sub-row Y / lerp h_a
saved_color     = scratch_4        ; colour for current segment

; ── Buffer allocations (BUFFERS segment) ────────────────────────────
.segment "BUFFERS"
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
    STA offset_tmp
    LDA obj_world_pos+OBJ_WORLD_SHIP+1   ; x hi
    ADC #>($20 - HALF_COLS * $40)         ; + $FF + carry
    ASL offset_tmp
    ROL A
    ASL offset_tmp
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
    STA offset_tmp
    LDA obj_world_pos+OBJ_WORLD_SHIP+5   ; z hi
    ADC #>($20 - (HALF_ROWS - 1) * $40)  ; + $FF + carry
    ASL offset_tmp
    ROL A
    ASL offset_tmp
    ROL A
    AND #$1F
    STA base_z
    ; z_cam = Z_NEAR_BOUND - (biased_lo & $3F)
    ; lo never borrows ($E0 - max $3F = $A1), so hi is constant
    TXA
    AND #$3F
    STA offset_tmp
    SEC
    LDA #<Z_NEAR_BOUND
    SBC offset_tmp
    STA z_cam_lo
    LDA #>Z_NEAR_BOUND
    STA z_cam_hi

    ; --- Grid dimensions ---
    ; Sets n_vtx (vertices per row, 8 or 9) and n_rows (vertex rows,
    ; 6 or 7). When sub_x or sub_z is exactly $20, one column/row is
    ; dropped because the edge vertices would coincide.
    ; === Determine n_vtx and n_rows (conditionally omit edge col/row) ===
    LDX #GRID_VTX_X
    LDA sub_x
    CMP #$20
    BNE @keep_x
    DEX
@keep_x:
    STX n_vtx
    LDY #GRID_VTX_Z
    LDA sub_z
    CMP #$20
    BNE @keep_z
    DEY
@keep_z:
    STY n_rows
    DEY
    STY n_rows_m1

    ; --- Interpolation offsets ---
    ; The grid edges don't align with heightmap cell boundaries. These
    ; offsets control how edge-row/column heights are interpolated
    ; between the two nearest heightmap cells, so the grid edges match
    ; exact screen boundaries rather than snapping to cell centres.
    ; === Compute interpolation offsets for edge height correction ===
    LDA sub_x
    JSR compute_interp_offsets
    STX interp_offset_l
    STA interp_offset_r

    ; === Compute Z interpolation offsets (same formula as X, using sub_z) ===
    LDA sub_z
    JSR compute_interp_offsets
    STX interp_offset_near
    STA interp_offset_far

    ; --- Precompute run_factor for sx_running ---
    ; sx_running = $4000 - K*recip, where K = 256 ± sub_x correction.
    ; sub_x in [0,$1F]: K = 256+sub_x → run_factor=sub_x, run_sub_recip=1
    ; sub_x in [$20,$3F]: K = $C0+sub_x → run_factor=$C0+sub_x, flag=0
    LDA sub_x
    CMP #$20
    BCS @rf_wrap
    STA run_factor
    LDX #1
    BCC @rf_done              ; always
@rf_wrap:
    CLC
    ADC #$C0
    STA run_factor
    LDX #0
@rf_done:
    STX run_sub_recip

    ; --- Initial hmap_ptr from base_z (inline set_hmap_ptr) ---
    ; hmap_ptr = height_map + hmap_row * 32, via (hmap_row:$00) >> 3
    ; height_map is page-aligned so lo byte of base is 0
    LDA base_z
    STA hmap_row
    STA hmap_ptr+1
    LDA #0
    LSR hmap_ptr+1
    ROR A
    LSR hmap_ptr+1
    ROR A
    LSR hmap_ptr+1
    ROR A                     ; hmap_ptr+1:A = hmap_row * 32
    STA hmap_ptr
    LDA hmap_ptr+1
    ADC #>height_map          ; C=0 from shifts
    STA hmap_ptr+1

    RECIP_NEAR = 65536 / (Z_NEAR_BOUND * 2)
    RECIP_FAR  = 65536 / (Z_FAR_BOUND * 2)

    ; === Row loop: j = 0..GRID_VTX_Z-1 ===
    LDA #0
    STA proj_row

    ; --- Row loop start & z_cam adjustment ---
    ; The main outer loop iterates over vertex rows (near → far). On
    ; row 0 (near edge), z_cam is nudged forward by interp_offset_near
    ; so it projects exactly at the near boundary. On the last row (far
    ; edge), z_cam is nudged backward similarly. These adjustments are
    ; reversed after the row is processed.

@row_loop:
    ; --- Reciprocal ---
    ; Boundary rows use compile-time constants; interior rows use table lookup.
    ; (Row 0's z_cam is below Z_NEAR_BOUND so can't index the table.)
    LDA proj_row
    BNE @not_row0
    LDA #RECIP_NEAR
    BNE @have_recip           ; always (RECIP_NEAR != 0)
@not_row0:
    CMP n_rows_m1
    BNE @use_table
    LDA #RECIP_FAR
    BNE @have_recip           ; always (RECIP_FAR != 0)
@use_table:
    LDA z_cam_lo
    STA math_b
    LDA z_cam_hi
    JSR recip8
@have_recip:
    STA recip_val

    ; --- Step & sx_running ---
    ; step = recip * 64 is the screen-x distance between adjacent
    ; vertices (one cell = 0.25 world units). It's a 16-bit value
    ; stored in step_lo/step_hi.
    ;
    ; sx_running starts at $4000 - 4*step, which places the leftmost
    ; vertex 4 cells left of centre (screen x = 64). The high byte is
    ; the screen-x coordinate.
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
    STA offset_tmp
    LDA recip_val
    SEC
    SBC offset_tmp
    STA edge_offset

    ; --- sx_running = $4000 - run_factor * recip [- recip*256] ---
    ; run_factor and run_sub_recip precomputed before the loop.
    ; Also sets math_b = recip_val for inline qsm + interp_height.
    LDA run_factor
    STA math_a
    LDA recip_val
    STA math_b
    JSR umul8x8
    LDA #0
    SEC
    SBC math_res_lo
    STA run_lo
    LDA #$40
    SBC math_res_hi
    LDX run_sub_recip
    BEQ :+
    SEC
    SBC recip_val
:   STA run_hi

    ; --- Heightmap next-row pointer: hmap_ptr + 32, wrapping at row 31 ---
    CLC
    LDA hmap_ptr
    ADC #32
    STA next_hmap_ptr
    LDA hmap_ptr+1
    ADC #0
    LDY hmap_row
    CPY #31
    BNE @no_hmap_wrap
    SEC
    SBC #4                    ; subtract $0400 (1024 bytes = 32 rows)
@no_hmap_wrap:
    STA next_hmap_ptr+1

    ; --- Z interpolation setup ---
    ; On boundary rows (near or far), heights need interpolating
    ; between the boundary row and the adjacent inner row. This sets
    ; z_interp_offset and interp_z_ptr — the inner row to blend toward.
    ; Interior rows skip this (offset = 0).
    LDA #0
    STA z_interp_offset           ; default: no Z interpolation
    LDA proj_row
    BNE @z_not_near
    ; Near row: inner row = next row
    LDA interp_offset_near
    BEQ @z_setup_done             ; offset 0 → skip
    STA z_interp_offset
    LDA next_hmap_ptr
    STA interp_z_ptr
    LDA next_hmap_ptr+1
    STA interp_z_ptr+1
    BNE @z_setup_done         ; always (hmap hi byte > 0)
@z_not_near:
    CMP n_rows_m1
    BNE @z_setup_done
    ; Far row: inner row = previous row
    LDA interp_offset_far
    CMP #64
    BCS @z_setup_done             ; 64 → skip
    STA z_interp_offset
    LDA prev_hmap_ptr
    STA interp_z_ptr
    LDA prev_hmap_ptr+1
    STA interp_z_ptr+1
@z_setup_done:

    ; Reset heightmap column for this row
    LDA base_x
    AND #$1F
    STA hmap_col

    ; --- Init v_off for this row ---
    LDX proj_row
    LDA v_row_offset_lo,X
    STA v_off

    ; --- Column loop preamble ---
    ; Sets proj_col as a countdown from n_vtx, then jumps into the
    ; inner loop. The uncommon @sea_cell path is placed before the
    ; hot loop so branch targets stay in range.
    ; --- Column loop: n_vtx vertices ---
    LDA n_vtx
    STA proj_col
    JMP @col_loop

    ; --- Uncommon paths (placed before hot loop for branch reach) ---
@sea_cell:
    INC saved_color           ; set sea flag (odd LUT index)
    LDX z_interp_offset
    BNE @z_interp_go
    JMP @do_height_mul        ; A=0 → flat sea
@z_interp_go:
    JSR z_interp_vertex       ; A = pre-scaled h*8
    BEQ @z_flat               ; zero → clear stale height, use flat sy
    ; Save Z-interpolated height in offset_tmp for edge interp corners
    STA offset_tmp            ; h*8
    BNE @do_height_mul        ; always
@z_flat:
    STA offset_tmp            ; A=0 — clear stale height for edge interp
    JMP @do_height_mul        ; A=0 → z-interp gave flat

    ; --- Height lookup & colour ---
    ; Reads the heightmap cell at hmap_col. The cell byte packs height
    ; in bits 7–3 and colour in bits 2–0. The colour bits are shifted
    ; into a LUT index (saved_color). Height 0 means sea —
    ; branches to @sea_cell which sets the sea flag (odd LUT index).

@col_loop:
    ; --- Height lookup, color precompute, and sy adjustment ---
    LDY hmap_col
    LDA (hmap_ptr),Y
    STA offset_tmp            ; save full byte for z_interp_vertex
    ; Precompute color LUT index: (offset_tmp << 1) & $0E | sea_flag
    ASL A
    AND #$0E
    STA saved_color           ; color base index (even=land, odd=sea)
    ; Extract height
    LDA offset_tmp
    AND #$F8                  ; h*8 directly
    BEQ @sea_cell             ; flat → set sea flag, check z_interp
    ; Land cell, height > 0
    LDX z_interp_offset
    BNE @z_interp_go          ; boundary row → interpolate
    ; (A already = h*8, fall through)
    ; Fall through to @do_height_mul
    ; --- Combined height-to-pixel multiplication ---
    ; Computes sy = 16 + cam_y_hi*recip + hi((cam_y_lo - h*8) * recip),
    ; with borrow correction when cam_y_lo < h*8. Uses an inlined
    ; quarter-square multiply (the hot path, so avoiding a JSR).
    ; Flat/sea cells enter with A=0 and get base sy naturally.

@do_height_mul:
    ; A = h*8 (0 for flat cells)
    STA seg_count             ; save h*8 for borrow check
    LDA cam_y_lo
    SEC
    SBC seg_count             ; A = cam_y_lo - h*8 (unsigned)
    ; Inline umul8x8 hi-byte: A * math_b (= recip_val, set by clamp)
    TAX                       ; save A
    SEC
    SBC math_b
    BCS @hm_dp
    EOR #$FF
    ADC #1                    ; C=0 from BCS not-taken
@hm_dp:
    TAY                       ; Y = |A - math_b|
    TXA                       ; restore A
    CLC
    ADC math_b
    TAX                       ; X = (A + math_b) & $FF
    BCC @hm_no
    SEC
    LDA sqr2_lo,X
    SBC sqr_lo,Y
    LDA sqr2_hi,X
    SBC sqr_hi,Y
    BCS @hm_end               ; always (quarter-square never borrows)
@hm_no:
    SEC
    LDA sqr_lo,X
    SBC sqr_lo,Y
    LDA sqr_hi,X
    SBC sqr_hi,Y
@hm_end:
    ; A = hi((cam_y_lo - h*8) * recip)
    JSR add_cam_y_offset      ; → A = sy, clamped ≥ 0

@sy_store:
    STA offset_tmp+1          ; save adjusted sy (borrow $A4 briefly)

    ; --- sx computation & edge clamping ---
    ; For middle vertices, sx is just run_hi (the running accumulator).
    ; The first and last vertices in the row are clamped to
    ; edge_offset boundaries and get height interpolation via
    ; interp_height — blending between the outer and inner heightmap
    ; cells so the grid edge matches the exact world boundary.
    ; --- sx: only first/last vertices need clamping ---
    LDX proj_col
    LDA run_hi
    CPX n_vtx                 ; first vertex?
    BEQ @do_left_clamp        ; always clamp to left boundary
    DEX                       ; proj_col - 1
    BNE @sx_done              ; middle vertices: no clamping
    ; Fall through: right edge (proj_col was 1)
    ; Interpolate height at right screen edge
    LDA hmap_col
    SEC
    SBC #1
    AND #$1F
    TAY                       ; Y = inner column
    LDA interp_offset_r
    JSR interp_height
    LDA edge_offset
    CLC
    ADC #64                   ; clamp_right = 64 + offset
    BNE @sx_done              ; always (>= 64)
@do_left_clamp:
    ; Interpolate height at left screen edge
    LDA hmap_col
    CLC
    ADC #1
    AND #$1F
    TAY                       ; Y = inner column
    LDA interp_offset_l
    JSR interp_height
    LDA #64
    SEC
    SBC edge_offset           ; clamp_left = 64 - offset
@sx_done:
    ; --- v_buf store & colour output ---
    ; Writes sx (+0) and sy (+1) to the current v_buf slot via v_off.
    ; v_color is stored at +2. h_color goes to pending_h_color for
    ; the next vertex's h-chain draw.
    ; A = final sx for this vertex
    STA raster_x1             ; cache for h-chain endpoint
    ; Store (sx, sy) to v_buf
    LDY v_off
    STA v_buf,Y               ; sx at offset 0
    LDA offset_tmp+1          ; final sy for this vertex
    STA raster_y1             ; cache for h-chain endpoint
    CMP grid_min_sy
    BCS @no_dirty_upd
    STA grid_min_sy
@no_dirty_upd:
    INY
    STA v_buf,Y               ; sy at offset 1
    STY v_off                 ; save (h-chain clobbers Y)

    ; --- Inline h-chain drawing ---
    ; First vertex: init raster state. Subsequent: draw from previous
    ; vertex using pending_h_color. Raster state (base, sub_y) is
    ; preserved between columns — no save/restore needed.
    LDA proj_col
    CMP n_vtx
    BNE @not_first_h
    ; First vertex: init raster at this position
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    JSR init_base
    JMP @h_chain_done
@not_first_h:
    LDA pending_h_color
    BEQ @h_black
    LDY h_chain_sub_y
    JSR draw_line
    JMP @h_drawn
@h_black:
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    JSR init_base
    JMP @h_chain_done
@h_drawn:
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
@h_chain_done:
    STY h_chain_sub_y

    ; --- Edge colours from precomputed index ---
    LDX saved_color
    LDA v_color_lut,X        ; v_color for this vertex
    LDY v_off                 ; restore (= off+1)
    INY
    STA v_buf,Y               ; v_color at off+2
    INY                       ; off+3 = next vertex
    STY v_off                 ; advance done
    LDA h_color_lut,X
    STA pending_h_color       ; for next vertex's h-chain draw

    ; --- Column loop advance ---
    ; Increments hmap_col (wrapping at 31) and adds step to
    ; sx_running. Decrements proj_col and loops until done.

    ; Advance heightmap column
    LDA hmap_col
    CLC
    ADC #1
    AND #$1F
    STA hmap_col

    ; sx_running += step
    LDA run_lo
    CLC
    ADC step_lo
    STA run_lo
    LDA run_hi
    ADC step_hi
    STA run_hi

    DEC proj_col
    BEQ @col_done
    JMP @col_loop
    ; --- Row loop tail ---
    ; After all columns: saves hmap_ptr as prev_hmap_ptr (needed if
    ; the next row is the far boundary row for Z interpolation).
    ; Reverses the near-row z_cam adjustment if this was row 0.
    ; Advances z_cam by $40 (one cell = 0.25 world units). Increments
    ; proj_row and loops.

@col_done:
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
    LDA hmap_row
    CLC
    ADC #1
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
    LDA proj_row
    CMP n_rows
    BCS @proj_done
    JMP @row_loop
    ; --- V-chain drawing ---
    ; After all rows are projected and h-chains drawn inline, v-chains
    ; are drawn column by column. For each column, grid_ptr walks down
    ; v_buf by ROW_STRIDE, reading v_color from +2.

@proj_done:
    ; --- Post-projection: draw v-chains column by column ---
    LDA #0
    STA proj_col
@v_col_loop:
    ; grid_ptr = v_buf + proj_col * 3
    LDA proj_col
    ASL A
    CLC
    ADC proj_col              ; A = col * 3
    CLC
    ADC #<v_buf
    STA grid_ptr
    LDA #>v_buf
    ADC #0
    STA grid_ptr+1

    LDA n_rows
    SEC
    SBC #1
    STA seg_count
    JSR draw_v_col

    INC proj_col
    LDA proj_col
    CMP n_vtx
    BCC @v_col_loop
    RTS

; =====================================================================
; draw_v_col — Draw one vertical chain from grid_ptr (ROW_STRIDE stride)
; =====================================================================
; Input:  grid_ptr = column start (row 0), seg_count = segments (n_rows - 1)
;
; Reads the first vertex's sx/sy and calls init_base. Then for each
; segment, advances grid_ptr by ROW_STRIDE, reads endpoint sx (+0),
; sy (+1), and v_color (+2). Black segments reposition via init_base.

draw_v_col:
    LDY #0
    LDA (grid_ptr),Y          ; sx
    STA raster_x0
    LDY #1
    LDA (grid_ptr),Y          ; sy
    STA raster_y0
    JSR init_base             ; Y = sub_y
@v_seg:
    STY saved_y
    ; Advance grid_ptr by ROW_STRIDE
    LDA grid_ptr
    CLC
    ADC #ROW_STRIDE
    STA grid_ptr
    BCC :+
    INC grid_ptr+1
:   LDY #0
    LDA (grid_ptr),Y          ; endpoint sx
    STA raster_x1
    INY
    LDA (grid_ptr),Y          ; endpoint sy
    STA raster_y1
    INY
    LDA (grid_ptr),Y          ; v_color
    BEQ @v_skip_black
    LDY saved_y
    JSR draw_line
    JMP @v_drawn
@v_skip_black:
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    JSR init_base
    DEC seg_count
    BNE @v_seg
    RTS
@v_drawn:
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    DEC seg_count
    BNE @v_seg
    RTS


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
; Input:  A = diff (1..31), seg_count = offset (0..63)
; Output: A = LUT value (pre-scaled delta)

lut_lookup:
    CMP #5
    BCS @ll_big               ; diff > 4 → multiply path
    SEC
    SBC #1                    ; diff - 1 (0..3)
    STA chain_idx
    LDA seg_count
    ASL A
    ASL A                     ; offset * 4
    ORA chain_idx             ; + (diff-1)
    TAX
    LDA interp_lut,X
    RTS
@ll_big:
    ; diff > 4: compute diff * offset / 8 via repeated addition
    TAX                       ; X = diff (loop counter)
    LDA #0
    STA chain_idx             ; hi byte of accumulator
@ll_add:
    CLC
    ADC seg_count
    BCC @ll_nc
    INC chain_idx
@ll_nc:
    DEX
    BNE @ll_add
    ; chain_idx:A = diff * offset; shift right 3
    LSR chain_idx
    ROR A
    LSR chain_idx
    ROR A
    LSR chain_idx
    ROR A
    RTS

; =====================================================================
; lerp_height — Interpolate from h_a towards h_b by offset
; =====================================================================
; Input:  A = h_a (0..31), chain_idx = h_b (0..31), seg_count = offset (0..63)
; Output: A = pre-scaled interpolated height (0..248)
; Clobbers: saved_y, chain_idx, X

lerp_height:
    CMP chain_idx
    BEQ @lh_same              ; same → return h_a × 8
    STA saved_y               ; save h_a
    BCC @lh_b_higher
    ; h_a > h_b: result = h_a×8 − delta_scaled
    SEC
    SBC chain_idx             ; diff (1..4)
    JSR lut_lookup            ; A = pre-scaled delta
    STA chain_idx
    LDA saved_y
    ASL A
    ASL A
    ASL A                     ; h_a × 8
    SEC
    SBC chain_idx
    RTS
@lh_b_higher:
    ; h_b > h_a: result = h_a×8 + delta_scaled
    LDA chain_idx
    SEC
    SBC saved_y               ; diff (1..4)
    JSR lut_lookup            ; A = pre-scaled delta
    STA chain_idx
    LDA saved_y
    ASL A
    ASL A
    ASL A                     ; h_a × 8
    CLC
    ADC chain_idx
    RTS
@lh_same:
    ASL A
    ASL A
    ASL A                     ; h_a × 8
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
; z_interp_vertex — Z-interpolate height in offset_tmp
; =====================================================================
; Interpolates offset_tmp's height (bits 3–7) between outer row (hmap_ptr)
; and inner row (interp_z_ptr) using z_interp_offset.
; Preserves colour bits (0–2) in offset_tmp.

z_interp_vertex:
    STX seg_count             ; X = z_interp_offset from caller
    LDY hmap_col
    LDA (interp_z_ptr),Y      ; inner row cell byte
    LSR A
    LSR A
    LSR A                     ; h_inner_z
    STA chain_idx
    LDA offset_tmp
    LSR A
    LSR A
    LSR A                     ; h_outer_z
    JMP lerp_height            ; tail call — A = pre-scaled (0..248)

; =====================================================================
; interp_height — Interpolate height between outer and inner cell
; =====================================================================
; Input:  Y = inner heightmap column, A = X interpolation offset (0..63)
; Effect: Recomputes offset_tmp+1 (sy) at interpolated height
; Handles corner-case bilinear interpolation (X + Z)

interp_height:
    PHA                       ; push X offset to stack
    LDA (hmap_ptr),Y          ; inner cell byte at inner column
    LSR A
    LSR A
    LSR A                     ; h_inner
    ; Z-interpolate h_inner if on boundary row (corner case)
    LDX z_interp_offset
    BEQ @ih_z_done
    STA saved_y               ; save h_inner_outer_row
    STX seg_count             ; Z offset
    LDA (interp_z_ptr),Y      ; inner row at inner column
    LSR A
    LSR A
    LSR A
    STA chain_idx             ; h_to
    LDA saved_y               ; h_from
    JSR lerp_height            ; A = pre-scaled Z-interpolated
    LSR A
    LSR A
    LSR A                     ; → height units
@ih_z_done:
    STA chain_idx             ; h_inner (Z-interpolated if corner)
    ; X-interpolate between h_outer and h_inner
    PLA                       ; recover X offset
    STA seg_count
    LDA offset_tmp
    LSR A
    LSR A
    LSR A                     ; h_outer (already Z-interpolated)
    CMP chain_idx
    BEQ @ih_done              ; same height → no change
    JSR lerp_height           ; A = pre-scaled h*8 (0..248)
    STA seg_count             ; save for borrow check
    LDA cam_y_lo
    SEC
    SBC seg_count
    STA math_a
    JSR umul8x8               ; math_b = recip_val
    LDA math_res_hi
    JSR add_cam_y_offset
    STA offset_tmp+1
@ih_done:
    RTS

