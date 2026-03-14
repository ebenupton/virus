; grid.s — Perspective grid projection and rendering for BBC Micro
;
; TODO: restore a single plot_final_pixel at the end of draw_grid
;       (top-right corner pixel is noticeably missing)
;
; Provides: draw_grid
; Requires: raster_zp.inc, math_zp.inc, grid_zp.inc
; Ext refs: cam_x_lo/hi, cam_z_lo/hi, height_map, urecip15, umul8x8,
;           init_base, draw_line

.include "raster_zp.inc"
.include "math_zp.inc"
.include "grid_zp.inc"

; ── Grid internal workspace (ZP_GRID internal) ────────────────────
; Pointers
grid_ptr        = ZP_GRID + 7      ; 2 bytes — prev-row ptr (v-chain draw)
hmap_ptr        = ZP_GRID + 9      ; 2 bytes — heightmap row pointer
hmap_next_ptr   = ZP_GRID + 11     ; 2 bytes — next heightmap row pointer
interp_z_ptr    = ZP_GRID + 13     ; 2 bytes — inner row heightmap pointer for Z interp
prev_hmap_ptr   = ZP_GRID + 15     ; 2 bytes — previous row's hmap_ptr (for far row)
v_ptr           = ZP_GRID + 17     ; 2 bytes — V buffer write pointer
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
sy_val          = ZP_GRID + 28     ; sy for current row (constant per row)
base_x          = ZP_GRID + 29     ; heightmap column base for column 0
base_z          = ZP_GRID + 30     ; heightmap row base for row 0
hmap_col        = ZP_GRID + 31     ; current heightmap column index (0..31)
hmap_row        = ZP_GRID + 32     ; current heightmap row index (0..31)
; Grid dimensions / clamps
n_vtx           = ZP_GRID + 33     ; vertices per row this frame
n_rows          = ZP_GRID + 34     ; vertex rows this frame
n_rows_m1       = ZP_GRID + 35     ; n_rows-1, precomputed for V-chain final pixel check
chain_state_idx = ZP_GRID + 36     ; index into chain_state[] for v-chain
clamp_left      = ZP_GRID + 37     ; left edge screen x clamp
clamp_right     = ZP_GRID + 38     ; right edge screen x clamp
clamp_near_sy   = ZP_GRID + 39     ; screen-y of near grid edge
clamp_far_sy    = ZP_GRID + 40     ; screen-y of far grid edge
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
v_buf:        .res GRID_VTX_Z * ROW_STRIDE + 3 ; row-major, 3 bytes/vertex (+3 pad for h_color lookahead)
v_color_buf:  .res GRID_VTX_X                  ; v-chain colour line buffer
chain_state:  .res GRID_VTX_X * 3              ; v-chain state per column
.segment "CODE"

; Row offset lookup (avoids ×44 multiply)
v_row_offset_lo:
    .byte <(0*ROW_STRIDE), <(1*ROW_STRIDE), <(2*ROW_STRIDE)
    .byte <(3*ROW_STRIDE), <(4*ROW_STRIDE), <(5*ROW_STRIDE)
    .byte <(6*ROW_STRIDE)
v_row_offset_hi:
    .byte >(0*ROW_STRIDE), >(1*ROW_STRIDE), >(2*ROW_STRIDE)
    .byte >(3*ROW_STRIDE), >(4*ROW_STRIDE), >(5*ROW_STRIDE)
    .byte >(6*ROW_STRIDE)

; Edge colour LUTs: index = (bits7-5 << 1) | sea_flag
; Split tables avoid runtime bit extraction (h=bits 4,2,0; v=bits 5,3,1)
h_color_lut:
    .byte $05,$14,$15,$14,$04,$10,$00,$10,$15,$14,$15,$14,$04,$10,$00,$10
v_color_lut:
    .byte $05,$14,$15,$14,$15,$14,$15,$14,$04,$10,$00,$10,$04,$10,$00,$10

; Step low-byte lookup: (recip & 3) << 6
step_lo_tbl:
    .byte $00, $40, $80, $C0

; Reciprocal table: recip_tbl[i] = floor(32768 / (Z_NEAR_BOUND + i))
; 321 entries covering z_cam = Z_NEAR_BOUND ($01E0) to Z_FAR_BOUND ($0320)
; Bakes in the ×2 so callers don't need to shift z_cam before lookup.
recip_tbl:
.repeat 321, i
    .byte 32768 / (Z_NEAR_BOUND + i)
.endrepeat

; =====================================================================
; draw_grid — Project grid + draw v-chains inline + draw h-chains
; =====================================================================
;
; Grid: GRID_COLS × GRID_ROWS cells, 0.25-unit spacing, centred on camera.
; Camera: (cam_x, -1.5, cam_z) — cam_y constant, no yaw.
; Projection: vx = 64·x_cam/z_cam, vy = 64·y_cam/z_cam,
;             screen centre (64, 16).
;
; Per-row: one urecip15 call gives recip ≈ 64/z_cam.
; sy_val = base sy from camera height (constant per row).
; Per-vertex height modulation: Δsy = h*recip/32 via umul8x8(h*8, recip).hi.
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

    ; --- Screen-y clamps ---
    ; Pre-computes the screen-y values where the near and far grid
    ; boundaries should appear. These are compile-time-constant Z
    ; distances, so their reciprocals are known. Used to clamp per-row
    ; sy so the grid edges align with exact world boundaries.
    ; === Compute clamp_near_sy from constant Z_NEAR_BOUND ===
    ; recip = 65536 / (Z_NEAR_BOUND * 2), compile-time constant
    RECIP_NEAR = 65536 / (Z_NEAR_BOUND * 2)
    LDA #RECIP_NEAR
    JSR mul_cam_y             ; A = recip * cam_y
    CLC
    ADC #16
    STA clamp_near_sy

    ; === Compute clamp_far_sy (far boundary screen-y) ===
    RECIP_FAR = 65536 / (Z_FAR_BOUND * 2)
    LDA #RECIP_FAR
    JSR mul_cam_y             ; A = recip * cam_y
    CLC
    ADC #16                   ; sy (can't overflow for far boundary)
    STA clamp_far_sy

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
    ; recip = recip_tbl[z_cam - Z_NEAR_BOUND], 2× baked into table
    LDA z_cam_lo
    SEC
    SBC #<Z_NEAR_BOUND
    TAY
    LDA z_cam_hi
    SBC #>Z_NEAR_BOUND        ; page 0 or 1
    BNE @recip_page1
    LDA recip_tbl,Y
    BNE @have_recip           ; always (recip > 0)
@recip_page1:
    LDA recip_tbl + 256,Y
@have_recip:
    STA recip_val

    ; --- sy computation ---
    ; sy = 16 + recip * cam_y, clamped between clamp_far_sy and
    ; clamp_near_sy. This is constant for the entire row (flat ground).
    ; Height modulation adjusts it per-vertex later. The +16 is the
    ; screen-y centre offset.
    ; --- sy = 16 + recip * cam_y, clamped to [clamp_far_sy, clamp_near_sy] ---
    JSR mul_cam_y             ; A = recip * cam_y
    BCS @sy_near_clamp        ; overflow → exceeds near clamp
    CLC
    ADC #16
    BCS @sy_near_clamp        ; overflow → exceeds near clamp
    CMP clamp_near_sy
    BCC @check_far_sy
@sy_near_clamp:
    LDA clamp_near_sy
@check_far_sy:
    CMP clamp_far_sy
    BCS @sy_ok
    LDA clamp_far_sy
@sy_ok:
    STA sy_val

    ; --- Step & sx_running ---
    ; step = recip * 64 is the screen-x distance between adjacent
    ; vertices (one cell = 0.25 world units). It's a 16-bit value,
    ; self-modifying-coded into the inner loop's ADC immediates for
    ; speed.
    ;
    ; sx_running starts at $4000 - 4*step, which places the leftmost
    ; vertex 4 cells left of centre (screen x = 64). The high byte is
    ; the screen-x coordinate.
    ; --- Step = recip * 64 (16-bit), the screen-x increment per cell ---
    LDA recip_val
    LSR A
    LSR A                     ; step_hi = recip >> 2
    STA step_hi
    STA @run_add_hi + 1      ; SMC: embed step_hi as immediate
    LDA recip_val
    AND #$03
    TAX
    LDA step_lo_tbl,X        ; (recip & 3) << 6
    STA step_lo
    STA @run_add_lo + 1      ; SMC: embed step_lo as immediate

    ; --- sx_running = $4000 - 4*step ---
    ; 4*step = 4*recip*64 = recip*256 → hi byte only, lo cancels
    LDA #0
    STA run_lo
    LDA #$40
    SEC
    SBC recip_val
    STA run_hi
    ; --- Edge clamps ---
    ; Computes the screen-x boundaries where the grid edges should
    ; appear. Vertices beyond these get clamped so the grid fills
    ; exactly to its world-space boundaries.
    ; --- Compute edge clamps ---
    ; offset = HALF_GRID_X * recip / 256 = hi($E0 * recip)
    LDA #HALF_GRID_X_LO
    STA math_a
    LDA recip_val
    STA math_b
    JSR umul8x8
    LDA math_res_hi           ; hi($E0 * recip)
    STA offset_tmp

    ; clamp_right = min(127, 64 + offset)
    CLC
    ADC #64
    BCS @cr_clamp             ; overflow → clamp
    CMP #128
    BCC @cr_ok
@cr_clamp:
    LDA #127
@cr_ok:
    STA clamp_right

    ; clamp_left = max(0, 64 - offset)
    LDA #64
    SEC
    SBC offset_tmp
    BCS @cl_ok
    LDA #0
@cl_ok:
    STA clamp_left

    ; --- sub_x offset ---
    ; Adjusts sx_running for the camera's fractional position within
    ; its heightmap cell. This shifts the grid left/right so vertices
    ; track the camera smoothly rather than snapping to cell boundaries.
    ; --- sub_x offset: adjust run for fractional camera position ---
    LDA cam_x_lo
    AND #$3F                  ; sub_x (0..63)
    BEQ @cam_x_done           ; sub_x == 0 → no offset
    CMP #$20
    BCS @x_wrap

    ; sub_x in [1,$1F]: run -= sub_x * recip
    STA math_a
    JSR umul8x8               ; math_b = recip_val (set by clamp, preserved)
    LDA run_lo
    SEC
    SBC math_res_lo
    STA run_lo
    LDA run_hi
    SBC math_res_hi
    STA run_hi
    JMP @cam_x_done

@x_wrap:
    ; sub_x in [$20,$3F]: run += ($40 - sub_x) * recip
    EOR #$3F
    ADC #0                    ; C=1 from BCS, so A = ~lo6 + 1 = $40 - sub_x
    STA math_a
    JSR umul8x8               ; math_b = recip_val (set by clamp, preserved)
    LDA run_lo
    CLC
    ADC math_res_lo
    STA run_lo
    LDA run_hi
    ADC math_res_hi
    STA run_hi
@cam_x_done:

    ; --- Heightmap pointers ---
    ; Sets up hmap_ptr for the current row's heightmap data, and
    ; hmap_next_ptr for the row behind it (wrapping at row 31 since
    ; the map is toroidal).
    ; --- Heightmap row pointer for this row ---
    LDA base_z
    CLC
    ADC proj_row
    AND #$1F
    STA hmap_row
    ; hmap_ptr = height_map + hmap_z * 32
    JSR set_hmap_ptr

    ; --- Heightmap next-row pointer: hmap_ptr + 32, wrapping at row 31 ---
    CLC
    LDA hmap_ptr
    ADC #32
    STA hmap_next_ptr
    LDA hmap_ptr+1
    ADC #0
    STA hmap_next_ptr+1
    LDA hmap_row
    CMP #31
    BNE @no_hmap_wrap
    LDA hmap_next_ptr+1
    SEC
    SBC #4                    ; subtract $0400 (1024 bytes = 32 rows)
    STA hmap_next_ptr+1
@no_hmap_wrap:

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
    LDA hmap_next_ptr
    STA interp_z_ptr
    LDA hmap_next_ptr+1
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

    ; --- v_ptr and grid_ptr init ---
    ; v_ptr points to the current row in v_buf (where we'll write
    ; projected vertices). grid_ptr points to the *previous* row in
    ; v_buf (where we'll read previous vertices for v-chain drawing).
    ; Skipped on row 0 since there's no previous row.
    ; --- Init v_ptr for this row ---
    LDX proj_row
    LDA v_row_offset_lo,X
    CLC
    ADC #<v_buf
    STA v_ptr
    LDA v_row_offset_hi,X
    ADC #>v_buf
    STA v_ptr+1

    ; --- Init grid_ptr = v_ptr - ROW_STRIDE (prev row, for V-chains) ---
    TXA                       ; set Z flag from proj_row (1 byte vs CPX #0)
    BEQ @skip_grid_init
    LDA v_ptr
    SEC
    SBC #ROW_STRIDE
    STA grid_ptr
    LDA v_ptr+1
    SBC #0
    STA grid_ptr+1
@skip_grid_init:

    ; --- Column loop preamble ---
    ; Sets proj_col as a countdown from n_vtx, resets chain_state_idx,
    ; then jumps into the inner loop. The uncommon @sea_cell path is
    ; placed before the hot loop so branch targets stay in range.
    ; --- Column loop: n_vtx vertices ---
    LDA n_vtx
    STA proj_col
    LDA #0
    STA chain_state_idx
    JMP @col_loop

    ; --- Uncommon paths (placed before hot loop for branch reach) ---
@sea_cell:
    INC saved_color           ; set sea flag (odd LUT index)
    LDX z_interp_offset
    BNE @z_interp_go
    JMP @use_sy_val
@z_interp_go:
    JSR z_interp_vertex       ; A = pre-scaled h*8
    BEQ @z_flat               ; zero → clear stale height, use sy_val
    ; Save Z-interpolated height in offset_tmp for edge interp corners
    TAX
    LSR A
    LSR A
    LSR A                     ; h (0..31)
    STA offset_tmp
    TXA
    BNE @do_height_mul        ; always (h*8 > 0 from BEQ check)

    ; --- Height lookup & colour ---
    ; Reads the heightmap cell at hmap_col. The cell byte packs 5 bits
    ; of height (0–31) and 3 bits of colour. The colour bits are
    ; shifted into a LUT index (saved_color). Height 0 means sea —
    ; branches to @sea_cell which sets the sea flag (odd LUT index).

@col_loop:
    ; --- Height lookup, color precompute, and sy adjustment ---
    LDY hmap_col
    LDA (hmap_ptr),Y
    STA offset_tmp            ; save full byte for z_interp_vertex
    ; Precompute color LUT index: (offset_tmp >> 4) & $0E | sea_flag
    LSR A
    LSR A
    LSR A
    LSR A
    AND #$0E
    STA saved_color           ; color base index (even=land, odd=sea)
    ; Extract height
    LDA offset_tmp
    AND #$1F                  ; height 0..31
    BEQ @sea_cell             ; flat → set sea flag, check z_interp
    ; Land cell, height > 0
    LDX z_interp_offset
    BNE @z_interp_go          ; boundary row → interpolate
    ASL A
    ASL A
    ASL A                     ; h * 8 (max 248, fits in byte)
    ; Fall through to @do_height_mul
    ; --- Height-to-pixel multiplication ---
    ; For non-zero height, computes hi(h*8 * recip_val) — the pixel
    ; offset for this height at this depth. This is an inlined
    ; quarter-square multiply (the hot path, so avoiding a JSR). The
    ; result is subtracted from sy_val to lift the vertex:
    ; sy = sy_val - height_offset, clamped to 0.
    ;
    ; Flat/sea cells skip the multiply and use sy_val directly.

@do_height_mul:
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
    ; A = hi(h*8 * recip_val); sy = sy_val - A, clamp ≥ 0
    EOR #$FF
    SEC
    ADC sy_val
    BCS @sy_store
    LDA #0
    BCC @sy_store

@z_flat:
    STA offset_tmp            ; A=0 — clear stale height for edge interp
@use_sy_val:
    LDA sy_val

@sy_store:
    STA offset_tmp+1          ; save adjusted sy (borrow $A4 briefly)

    ; --- sx computation & edge clamping ---
    ; For middle vertices, sx is just run_hi (the running accumulator).
    ; The first and last vertices in the row are clamped to
    ; clamp_left/clamp_right and get height interpolation via
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
    LDA clamp_right
    BNE @sx_done              ; always (clamp_right >= 64)
@do_left_clamp:
    ; Interpolate height at left screen edge
    LDA hmap_col
    CLC
    ADC #1
    AND #$1F
    TAY                       ; Y = inner column
    LDA interp_offset_l
    JSR interp_height
    LDA clamp_left
@sx_done:
    ; --- v_buf store & colour output ---
    ; Writes sx (+0) and sy (+1) to the current v_buf slot. h_color is
    ; written at v_ptr+5 (the *next* vertex's +2 slot, ready for
    ; h-chain drawing). v_color goes into v_color_buf — reads the old
    ; value (previous row's colour for v-chain drawing) before writing
    ; the new one.
    ; A = final sx for this vertex
    STA raster_x1             ; cache for V-chain endpoint
    ; Store (sx, sy) to v_buf; h_color to next vertex's +2
    LDY #0
    STA (v_ptr),Y             ; sx at offset 0
    LDA offset_tmp+1          ; final sy for this vertex
    STA raster_y1             ; cache for V-chain endpoint
    CMP grid_min_sy
    BCS @no_dirty_upd
    STA grid_min_sy
@no_dirty_upd:
    LDY #1
    STA (v_ptr),Y
    ; --- Edge colours from precomputed index ---
    LDX saved_color
    LDA h_color_lut,X
    LDY #5
    STA (v_ptr),Y             ; store at next vertex's +2 slot
    LDA v_color_lut,X         ; new v_color
    LDX proj_col
    LDY v_color_buf - 1,X     ; read old v_color (prev row)
    STA v_color_buf - 1,X     ; write new v_color
    STY saved_color           ; old v_color ready for v-chain draw

    ; --- Inline v-chain drawing ---
    ; Skipped on row 0 (no previous row to connect to). For rows 1+:
    ;
    ; - Reads the previous row's vertex from grid_ptr (sx, sy →
    ;   raster start point)
    ; - On row 1, calls init_base to establish the chain's raster
    ;   state. On rows 2+, restores saved chain state (sub-pixel Y
    ;   position and base pointer) from chain_state[]
    ; - saved_color holds the old v_color (read from v_color_buf
    ;   earlier). If black, skips drawing and repositions the chain at
    ;   the endpoint via init_base. Otherwise calls draw_line
    ; - Saves chain state (3 bytes: sub_y, raster_base lo/hi) for the
    ;   next row
    ; - Advances grid_ptr by 3 to the next column's previous-row vertex
    ; --- Inline vertical chain drawing ---
    LDA proj_row
    BEQ @no_v_draw

    ; grid_ptr already points to prev row vertex (init at row start)

    ; Start point = previous row vertex
    LDY #0
    LDA (grid_ptr),Y          ; prev sx
    STA raster_x0
    LDY #1
    LDA (grid_ptr),Y          ; prev sy
    STA raster_y0

    ; Chain state: init_base on row 1, restore on row 2+
    LDX chain_state_idx
    LDA proj_row
    CMP #1                    ; Z=1 iff proj_row==1
    BNE @v_restore
    JSR init_base             ; Y = sub_y
    JMP @v_ready
@v_restore:
    LDY chain_state,X
    LDA chain_state+1,X
    STA raster_base
    LDA chain_state+2,X
    STA raster_base+1
@v_ready:
    ; Endpoint = current vertex (raster_x1/y1 cached from v_buf write)

    ; Draw (skip black lines)
    LDA saved_color           ; v_color
    BEQ @v_skip_black
    JSR draw_line             ; Y = sub_y
    JMP @v_drawn
@v_skip_black:
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    JSR init_base             ; reposition at endpoint
@v_drawn:

    ; Save chain state
    LDX chain_state_idx
    TYA
    STA chain_state,X
    LDA raster_base
    STA chain_state+1,X
    LDA raster_base+1
    STA chain_state+2,X
    ; Advance chain_state_idx
    INX
    INX
    INX
    STX chain_state_idx

    ; Advance grid_ptr for next column's V-chain
    LDA grid_ptr
    CLC
    ADC #3
    STA grid_ptr
    BCC :+
    INC grid_ptr+1
:
@no_v_draw:

    ; --- Column loop advance ---
    ; Increments hmap_col (wrapping at 31), advances v_ptr by 3, and
    ; adds step to sx_running (SMC'd 16-bit add). Decrements proj_col
    ; and loops until all vertices are done.

    ; Advance heightmap column
    LDA hmap_col
    CLC
    ADC #1
    AND #$1F
    STA hmap_col

    ; Advance v_ptr += 3
    LDA v_ptr
    CLC
    ADC #3
    STA v_ptr
    BCC @no_vpc
    INC v_ptr+1
@no_vpc:

    ; sx_running += step (SMC: immediate operands)
    LDA run_lo
    CLC
@run_add_lo:
    ADC #$00                  ; SMC'd to step_lo
    STA run_lo
    LDA run_hi
@run_add_hi:
    ADC #$00                  ; SMC'd to step_hi
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
    ; Save hmap_ptr for far-row Z interpolation
    LDA hmap_ptr
    STA prev_hmap_ptr
    LDA hmap_ptr+1
    STA prev_hmap_ptr+1

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
    ; --- H-chain drawing ---
    ; After all rows are projected and v-chains drawn, h-chains are
    ; drawn back-to-front (far row first, near row last) so nearer
    ; lines overwrite farther ones.
    ;
    ; For each row, grid_ptr is set to the row's v_buf start and
    ; seg_count = n_vtx - 1.

@proj_done:
    ; --- Post-projection: draw h-chains row by row (back-to-front) ---
    LDA n_rows_m1
    STA proj_row
@h_row_loop:
    ; grid_ptr = v_buf + row offset
    LDX proj_row
    LDA v_row_offset_lo,X
    CLC
    ADC #<v_buf
    STA grid_ptr
    LDA v_row_offset_hi,X
    ADC #>v_buf
    STA grid_ptr+1

    LDX n_vtx
    DEX
    STX seg_count
    JSR draw_h_row

    DEC proj_row
    BPL @h_row_loop
    RTS

; =====================================================================
; draw_h_row — Draw one horizontal chain from grid_ptr (3-byte stride)
; =====================================================================
; Input:  grid_ptr = row start, seg_count = segments (n_vtx - 1)
;
; Reads the first vertex's sx/sy and calls init_base to establish the
; chain's raster state. Then for each segment:
;
; - Advances grid_ptr by 3 to the next vertex
; - Reads endpoint sx (+0), sy (+1), and h_color (+2) sequentially.
;   The h_color at +2 was written there during projection by the
;   *previous* vertex (at its v_ptr+5)
; - If h_color is black (0), skips drawing — repositions the chain at
;   the endpoint via init_base (breaking the chain)
; - Otherwise calls draw_line, then copies endpoint to start point for
;   the next segment
; - After the last segment, returns (no final pixel)

draw_h_row:
    LDY #0
    LDA (grid_ptr),Y          ; sx
    STA raster_x0
    LDY #1
    LDA (grid_ptr),Y          ; sy
    STA raster_y0
    JSR init_base             ; Y = sub_y
@h_seg:
    STY saved_y
    ; Advance grid_ptr to next vertex
    LDA grid_ptr
    CLC
    ADC #3
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
    LDA (grid_ptr),Y          ; h_color (stored here by prev vertex)
    BEQ @h_skip_black
    LDY saved_y
    JSR draw_line
    JMP @h_drawn
@h_skip_black:
    ; Black segment: reposition at endpoint without drawing
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    JSR init_base             ; reposition chain at next vertex
    DEC seg_count
    BNE @h_seg
    RTS                       ; last segment was black, no final pixel
@h_drawn:
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    DEC seg_count
    BNE @h_seg
    RTS

; =====================================================================
; set_hmap_ptr — Set hmap_ptr from heightmap row index
; =====================================================================
; Input:  A = hmap row index (0..31)
; Output: hmap_ptr set, X = input A (preserved for caller)

set_hmap_ptr:
    TAX
    LSR A
    LSR A
    LSR A                     ; hmap_z >> 3
    CLC
    ADC #>height_map
    STA hmap_ptr+1
    TXA
    AND #$07
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A                     ; (hmap_z & 7) << 5, C=0 (max 224)
    ADC #<height_map
    STA hmap_ptr
    BCC :+
    INC hmap_ptr+1
:   RTS

; =====================================================================
; mul_cam_y — Multiply recip by cam_y (8.8), return pixel offset
; =====================================================================
; Input:  A = recip (8-bit unsigned)
; Output: A = recip * cam_y (integer part), C set if overflow
; Clobbers: math_a, math_b, math_res, offset_tmp

mul_cam_y:
    STA math_a
    ; Integer part: recip * cam_y_hi via adds (cam_y_hi is 0-2)
    LDX cam_y_hi
    BEQ @mcy_int_zero
    DEX
    BEQ @mcy_int_done         ; cam_y_hi == 1: A = recip
    ASL A                     ; cam_y_hi == 2: A = 2*recip
    BCS @mcy_overflow
    DEX
    BEQ @mcy_int_done
    BCC @mcy_overflow         ; cam_y_hi >= 3: overflow
@mcy_int_zero:
    LDA #0
@mcy_int_done:
    PHA                       ; save integer contribution
    ; Fractional part: (recip * cam_y_lo) >> 8
    LDA cam_y_lo
    STA math_b
    JSR umul8x8
    PLA                       ; integer contribution
    CLC
    ADC math_res_hi           ; + fractional high byte
    BCC @mcy_done
@mcy_overflow:
    LDA #$FF                  ; saturate
    SEC
@mcy_done:
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
; Interpolates offset_tmp's height (bits 0–4) between outer row (hmap_ptr)
; and inner row (interp_z_ptr) using z_interp_offset.
; Preserves colour bits (5–7) in offset_tmp.

z_interp_vertex:
    STX seg_count             ; X = z_interp_offset from caller
    LDY hmap_col
    LDA (interp_z_ptr),Y      ; inner row cell byte
    AND #$1F                  ; h_inner_z
    STA chain_idx
    LDA offset_tmp
    AND #$1F                  ; h_outer_z
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
    AND #$1F                  ; h_inner
    ; Z-interpolate h_inner if on boundary row (corner case)
    LDX z_interp_offset
    BEQ @ih_z_done
    STA saved_y               ; save h_inner_outer_row
    STX seg_count             ; Z offset
    LDA (interp_z_ptr),Y      ; inner row at inner column
    AND #$1F
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
    AND #$1F                  ; h_outer (already Z-interpolated)
    CMP chain_idx
    BEQ @ih_done              ; same height → no change
    JSR lerp_height            ; A = pre-scaled (0..248)
    ; Convert interpolated height to sy
    BEQ @ih_base_sy
    STA math_a                ; already world-coord scale
    JSR umul8x8               ; math_b = recip_val (set by clamp, preserved)
    LDA sy_val
    SEC
    SBC math_res_hi
    BCS @ih_sy_ok
    LDA #0
@ih_sy_ok:
    STA offset_tmp+1
@ih_done:
    RTS
@ih_base_sy:
    LDA sy_val
    STA offset_tmp+1
    RTS

