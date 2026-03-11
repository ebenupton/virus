; grid.s — Perspective grid projection and rendering for BBC Micro
;
; Provides: draw_grid
; Requires: raster_zp.inc, math_zp.inc, grid_zp.inc
; Ext refs: cam_x_lo/hi, cam_z_lo/hi, height_map, urecip15, umul8x8,
;           init_base, draw_line

.include "raster_zp.inc"
.include "math_zp.inc"
.include "grid_zp.inc"

; ── Grid workspace ($90-$B2, 3 blocks) ─────────────────────────────
; Projection
grid_ptr        = $90       ; 2 bytes — grid_ptr in draw; sx/h_color temp during projection
hmap_ptr        = $92       ; 2 bytes — heightmap row pointer
proj_col        = $94       ; inner loop counter (vertices remaining)
hmap_col        = $95       ; current heightmap column index (0..31)
z_cam_lo        = $96       ; z_cam low byte (8.8 fractional part, running)
z_cam_hi        = $97       ; z_cam high byte (8.8 integer part, running)
proj_row        = $98       ; outer loop counter (row index)
recip_val       = $99       ; recip for current row (≈ 64/z_cam)
step_lo         = $9A       ; x step low byte (recip * 64, fractional)
step_hi         = $9B       ; x step high byte (recip * 64, integer)
base_x          = $9C       ; heightmap column base for column 0
run_lo          = $9D       ; sx running accumulator low byte
run_hi          = $9E       ; sx running accumulator high byte
sy_val          = $9F       ; sy for current row (constant per row)
base_z          = $A0       ; heightmap row base for row 0
v_ptr           = $A1       ; 2 bytes — V buffer write pointer
offset_tmp      = $A3       ; scratch (replaces temp2 usage)
; Draw
seg_count       = $A5       ; segments remaining in current chain
chain_idx       = $A6       ; byte offset within current chain
saved_y         = $A7       ; saved sub-row Y during chain iteration
saved_color     = $A8       ; colour for current segment
clamp_left      = $A9       ; left edge screen x clamp (draw_grid)
clamp_right     = $AC       ; right edge screen x clamp
; Shared (set in project, read in draw)
n_vtx           = $AD       ; vertices per row this frame
chain_state_idx = $AE       ; index into chain_state[] for v-chain
n_rows          = $AF       ; vertex rows this frame
hmap_row        = $B0       ; current heightmap row index (0..31)
clamp_near_sy   = $B1       ; screen-y of near grid edge
clamp_far_sy    = $B2       ; screen-y of far grid edge
hmap_next_ptr   = $B3       ; 2 bytes — next heightmap row pointer (for v-edge colour)
interp_offset_l = $B5       ; left-edge interpolation offset (0..63)
interp_offset_r = $B6       ; right-edge interpolation offset (0..63)
interp_offset_near = $B7    ; near-row Z interpolation offset (0..63)
interp_offset_far  = $B8    ; far-row Z interpolation offset (0..64, 64=skip)
z_interp_offset    = $B9    ; current row's Z offset (0 = no Z interp)
interp_z_ptr       = $BA    ; 2 bytes — inner row heightmap pointer for Z interp
prev_hmap_ptr      = $BC    ; 2 bytes — previous row's hmap_ptr (for far row)
; grid_min_sy = $BE declared in grid_zp.inc

; ── Buffer allocations (BUFFERS segment) ────────────────────────────
.segment "BUFFERS"
v_buf:        .res GRID_VTX_Z * ROW_STRIDE    ; row-major, 4 bytes/vertex
chain_state:  .res GRID_VTX_X * 3              ; v-chain state per column
.segment "CODE"

; Row offset lookup (avoids ×44 multiply)
v_row_offset_lo:
    .byte <(0*ROW_STRIDE), <(1*ROW_STRIDE), <(2*ROW_STRIDE)
    .byte <(3*ROW_STRIDE), <(4*ROW_STRIDE), <(5*ROW_STRIDE)
    .byte <(6*ROW_STRIDE), <(7*ROW_STRIDE), <(8*ROW_STRIDE)
v_row_offset_hi:
    .byte >(0*ROW_STRIDE), >(1*ROW_STRIDE), >(2*ROW_STRIDE)
    .byte >(3*ROW_STRIDE), >(4*ROW_STRIDE), >(5*ROW_STRIDE)
    .byte >(6*ROW_STRIDE), >(7*ROW_STRIDE), >(8*ROW_STRIDE)

; ── Colour unpack table: 3-bit packed → MODE 2 right-pixel (bits 4,2,0) ──
; 0=black, 1=red, 2=green, 3=yellow, 4=blue, 5=magenta, 6=cyan, 7=white
color_unpack:
    .byte $00, $01, $04, $05, $10, $11, $14, $15

; Edge colour LUT: index = (bits7-5 << 1) | sea_flag
; Packed byte: h_color in bits 4,2,0; v_color in bits 5,3,1
; Extract h: AND #$15   Extract v: LSR then AND #$15
edge_color_lut:
    .byte $0F,$3C,$3F,$3C,$2E,$38,$2A,$38,$1D,$34,$15,$34,$0C,$30,$00,$30

; Step low-byte lookup: (recip & 3) << 6
step_lo_tbl:
    .byte $00, $40, $80, $C0

; =====================================================================
; draw_grid — Project grid + draw v-chains inline + draw h-chains
; =====================================================================
;
; Grid: GRID_COLS × GRID_ROWS cells, 0.25-unit spacing, centred on camera.
; Camera: (cam_x, -1.5, cam_z) — cam_y constant, no yaw.
; Projection: vx = 64·x_cam/z_cam, vy = 64·y_cam/z_cam,
;             screen centre (64, 80).
;
; Per-row: one urecip15 call gives recip ≈ 64/z_cam.
; sy_val = base sy from camera height (constant per row).
; Per-vertex height modulation: Δsy = h*recip/32 via umul8x8(h*8, recip).hi.
; sx advances by a constant step = recip·0.25 per vertex (16-bit add).

draw_grid:
    LDA #160
    STA grid_min_sy

    ; === Compute z_cam for row 0 ===
    ; z_cam = CAM_Z_BEHIND - HALF_ROWS*$40 - sub_z (from cam position)
    LDA cam_z_lo
    AND #$3F                  ; sub_z (0..63)
    CMP #$20
    BCS @z_wrap
    ; sub_z < $20: z_cam = (CAM_Z_BEHIND - HALF_ROWS*$40) - sub_z
    STA offset_tmp
    SEC
    LDA #<(CAM_Z_BEHIND - HALF_ROWS * $40)
    SBC offset_tmp
    STA z_cam_lo
    LDA #>(CAM_Z_BEHIND - HALF_ROWS * $40)
    SBC #0
    STA z_cam_hi
    BRA @z_done
@z_wrap:
    ; sub_z >= $20: z_cam = (CAM_Z_BEHIND - (HALF_ROWS-1)*$40) - sub_z
    STA offset_tmp
    SEC
    LDA #<(CAM_Z_BEHIND - (HALF_ROWS - 1) * $40)
    SBC offset_tmp
    STA z_cam_lo
    LDA #>(CAM_Z_BEHIND - (HALF_ROWS - 1) * $40)
    SBC #0
    STA z_cam_hi
@z_done:

    ; === Cache sub_x/sub_z (ship fractional position within cell) ===
    LDA obj_world_pos+OBJ_WORLD_SHIP+0
    AND #$3F
    STA grid_ptr              ; sub_x cached at $90
    LDA obj_world_pos+OBJ_WORLD_SHIP+4
    AND #$3F
    STA grid_ptr+1            ; sub_z cached at $91

    ; === Compute heightmap base indices (centred on ship, not camera) ===
    ; base_x (save ship col on stack for terrain lookup)
    LDY #0
    JSR ship_hmap_col         ; A = ship_x hmap col (0..31)
    PHA                       ; save for terrain lookup
    SEC
    SBC #HALF_COLS
    STA base_x
    LDA grid_ptr              ; sub_x
    CMP #$20
    BCC @bx_done
    INC base_x
@bx_done:
    ; base_z (save ship row on stack for terrain lookup)
    LDY #4
    JSR ship_hmap_col         ; A = ship_z hmap row (0..31)
    PHA                       ; save for terrain lookup
    SEC
    SBC #HALF_ROWS
    STA base_z
    LDA grid_ptr+1            ; sub_z
    CMP #$20
    BCC @bz_done
    INC base_z
@bz_done:

    ; === Sample terrain height at ship position for ground clamp ===
    PLA                       ; ship_z hmap row
    JSR set_hmap_ptr
    PLY                       ; ship_x hmap col
    LDA (hmap_ptr),Y
    AND #$1F
    ASL A
    ASL A
    STA terrain_y              ; height * 4 (cam follows ship, halving effective offset)

    ; === Determine n_vtx based on sub_x ===
    LDA grid_ptr              ; sub_x
    CMP #$20
    BNE @full_grid
    ; sub_x == $20: omit rightmost column
    LDA #(GRID_VTX_X - 1)
    STA n_vtx
    BRA @grid_size_done
@full_grid:
    LDA #GRID_VTX_X
    STA n_vtx
@grid_size_done:

    ; === Determine n_rows based on sub_z ===
    LDA grid_ptr+1            ; sub_z
    CMP #$20
    BNE @full_z
    ; sub_z == $20: omit farthest row
    LDA #(GRID_VTX_Z - 1)
    STA n_rows
    BRA @z_size_done
@full_z:
    LDA #GRID_VTX_Z
    STA n_rows
@z_size_done:

    ; === Compute interpolation offsets for edge height correction ===
    LDA grid_ptr              ; sub_x
    CMP #$20
    BCS @interp_hi
    ; sub_x < $20: offset_l = 32 + sub_x, offset_r = 32 - sub_x
    STA offset_tmp
    CLC
    ADC #32
    STA interp_offset_l
    LDA #32
    SEC
    SBC offset_tmp
    STA interp_offset_r
    BRA @interp_done
@interp_hi:
    ; sub_x >= $20: offset_l = sub_x - 32, offset_r = 96 - sub_x
    STA offset_tmp
    SEC
    SBC #32
    STA interp_offset_l
    LDA #96
    SEC
    SBC offset_tmp
    STA interp_offset_r
@interp_done:

    ; === Compute Z interpolation offsets (same formula as X, using sub_z) ===
    LDA grid_ptr+1            ; sub_z
    CMP #$20
    BCS @z_interp_hi
    ; sub_z < $20: offset_near = 32 + sub_z, offset_far = 32 - sub_z
    STA offset_tmp
    CLC
    ADC #32
    STA interp_offset_near
    LDA #32
    SEC
    SBC offset_tmp
    STA interp_offset_far
    BRA @z_interp_done
@z_interp_hi:
    ; sub_z >= $20: offset_near = sub_z - 32, offset_far = 96 - sub_z
    STA offset_tmp
    SEC
    SBC #32
    STA interp_offset_near
    LDA #96
    SEC
    SBC offset_tmp
    STA interp_offset_far
@z_interp_done:

    ; === Compute clamp_near_sy from constant Z_NEAR_BOUND ===
    ; recip = 65536 / (Z_NEAR_BOUND * 4), compile-time constant
    RECIP_NEAR = 65536 / (Z_NEAR_BOUND * 4)
    LDA #RECIP_NEAR
    JSR mul_cam_y             ; A = recip * cam_y
    CLC
    ADC #80
    STA clamp_near_sy

    ; === Compute clamp_far_sy (far boundary screen-y) ===
    RECIP_FAR = 65536 / (Z_FAR_BOUND * 4)
    LDA #RECIP_FAR
    JSR mul_cam_y             ; A = recip * cam_y
    CLC
    ADC #80                   ; sy (can't overflow for far boundary)
    STA clamp_far_sy

    ; === Row loop: j = 0..GRID_VTX_Z-1 ===
    STZ proj_row

@row_loop:
    ; --- Skip if z_cam <= 0 (behind or on camera plane) ---
    LDA z_cam_hi
    BMI @do_skip              ; negative → behind camera
    ORA z_cam_lo
    BNE @z_cam_ok             ; non-zero positive → proceed
@do_skip:
    JMP @skip_row
@z_cam_ok:

    ; --- Adjust z_cam for boundary rows ---
    LDA proj_row
    BNE @not_near_adj
    ; Near row: z_cam += interp_offset_near → projects at Z_NEAR_BOUND
    LDA interp_offset_near
    BEQ @no_z_adj
    CLC
    ADC z_cam_lo
    STA z_cam_lo
    LDA z_cam_hi
    ADC #0
    STA z_cam_hi
    BRA @no_z_adj
@not_near_adj:
    ; Far row check: proj_row + 1 == n_rows?
    LDA proj_row
    INC A
    CMP n_rows
    BNE @no_z_adj
    ; Far row: z_cam -= interp_offset_far → projects at Z_FAR_BOUND
    LDA interp_offset_far
    CMP #64
    BCS @no_z_adj             ; 64 = boundary aligned, no adjustment
    STA offset_tmp
    LDA z_cam_lo
    SEC
    SBC offset_tmp
    STA z_cam_lo
    LDA z_cam_hi
    SBC #0
    STA z_cam_hi
@no_z_adj:

    ; --- Reciprocal: recip = urecip15(z_cam << 2) ≈ 64/z_cam ---
    LDA z_cam_lo
    ASL A
    STA math_b
    LDA z_cam_hi
    ROL A
    ASL math_b
    ROL A
    STA math_a
    JSR urecip15
    LDA math_res_lo           ; recip fits in low byte for our z range
    STA recip_val

    ; --- sy = 80 + recip * cam_y, clamped to [clamp_far_sy, clamp_near_sy] ---
    JSR mul_cam_y             ; A = recip * cam_y
    BCS @sy_near_clamp        ; overflow → exceeds near clamp
    CLC
    ADC #80
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

    ; --- Step = recip * 64 (16-bit), the screen-x increment per cell ---
    LDA recip_val
    LSR A
    LSR A                     ; step_hi = recip >> 2
    STA step_hi
    LDA recip_val
    AND #$03
    TAX
    LDA step_lo_tbl,X        ; (recip & 3) << 6
    STA step_lo

    ; --- sx_running = $4000 - 5*step ---
    ; 5*step = 5*recip*64 = recip*320 = recip*256 + recip*64 = recip*256 + step
    LDA #$00
    SEC
    SBC step_lo
    STA run_lo
    LDA #$40
    SBC step_hi               ; - step_hi - borrow_lo
    SBC recip_val              ; - recip (= -256*recip in hi byte)
    STA run_hi
    ; --- Compute edge clamps ---
    ; offset = HALF_GRID_X * recip / 256
    LDA #HALF_GRID_X_LO
    STA math_a
    LDA recip_val
    STA math_b
    JSR umul8x8
    LDA math_res_hi           ; hi($20 * recip), max 31
    CLC
    ADC recip_val             ; offset = recip + hi part (9-bit, max 286)
    BCS @clamp_full           ; carry → offset >= 256, full screen visible
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
    BRA @clamp_done

@clamp_full:
    ; Offset >= 256: entire screen within grid
    LDA #127
    STA clamp_right
    STZ clamp_left
@clamp_done:

    ; --- sub_x offset: adjust run for fractional camera position ---
    LDA cam_x_lo
    AND #$3F                  ; sub_x (0..63)
    BEQ @cam_x_done           ; sub_x == 0 → no offset
    CMP #$20
    BCS @x_wrap

    ; sub_x in [1,$1F]: run -= sub_x * recip
    STA math_a
    LDA recip_val
    STA math_b
    JSR umul8x8
    LDA run_lo
    SEC
    SBC math_res_lo
    STA run_lo
    LDA run_hi
    SBC math_res_hi
    STA run_hi
    BRA @cam_x_done

@x_wrap:
    ; sub_x in [$20,$3F]: run += ($40 - sub_x) * recip
    EOR #$3F
    INC A                     ; A = $40 - sub_x (1..$20)
    STA math_a
    LDA recip_val
    STA math_b
    JSR umul8x8
    LDA run_lo
    CLC
    ADC math_res_lo
    STA run_lo
    LDA run_hi
    ADC math_res_hi
    STA run_hi
@cam_x_done:

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
    STZ z_interp_offset           ; default: no Z interpolation
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
    BRA @z_setup_done
@z_not_near:
    INC A
    CMP n_rows
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
    CPX #0
    BEQ @skip_grid_init
    LDA v_ptr
    SEC
    SBC #ROW_STRIDE
    STA grid_ptr
    LDA v_ptr+1
    SBC #0
    STA grid_ptr+1
@skip_grid_init:

    ; --- Column loop: n_vtx vertices ---
    LDA n_vtx
    STA proj_col
    STZ chain_state_idx

@col_loop:
    ; --- Height lookup and sy adjustment ---
    LDY hmap_col
    LDA (hmap_ptr),Y
    STA offset_tmp            ; save full byte for color extraction
    ; Z-interpolate height if on a boundary row
    LDA z_interp_offset
    BEQ @no_z_interp
    JSR z_interp_vertex       ; A = pre-scaled h*8 (0..248)
    BEQ @use_sy_val           ; zero → sea/flat
    STA math_a                ; already pre-scaled, skip ×8
    BRA @do_height_mul
@no_z_interp:
    LDA offset_tmp
    AND #$1F                  ; height 0..31
    BEQ @use_sy_val           ; flat → use row's base sy

    ; Δsy = hi_byte(h*8 * recip) = h * recip / 32
    ASL A
    ASL A
    ASL A                     ; h * 8 (max 248, fits in byte)
    STA math_a
@do_height_mul:
    LDA recip_val
    STA math_b
    JSR umul8x8
    ; sy_vertex = sy_val - Δsy, clamp to 0
    LDA sy_val
    SEC
    SBC math_res_hi
    BCS @sy_vert_ok
    LDA #0                    ; underflow → clamp to 0
@sy_vert_ok:
    BRA @sy_vert_done

@use_sy_val:
    LDA sy_val

@sy_vert_done:
    STA offset_tmp+1          ; save adjusted sy (borrow $A4 briefly)

    ; --- sx: only first/last vertices need clamping ---
    LDX proj_col
    LDA run_hi
    CPX n_vtx                 ; first vertex?
    BEQ @clamp_left_edge
    CPX #1                    ; last vertex?
    BEQ @clamp_right_edge
    BRA @sx_done
@clamp_left_edge:
    ; First vertex: sx = max(clamp_left, run_hi)
    CMP #128
    BCS @do_left_clamp        ; run_hi >= 128 → wrapped negative
    CMP clamp_left
    BCS @sx_done              ; run_hi >= clamp_left → no clamp
@do_left_clamp:
    ; Interpolate height at left screen edge
    LDA hmap_col
    INC A
    AND #$1F
    TAY                       ; Y = inner column
    LDA interp_offset_l
    JSR interp_height
    LDA clamp_left
    BRA @sx_done
@clamp_right_edge:
    ; Last vertex: sx = min(clamp_right, run_hi)
    CMP clamp_right
    BCC @sx_done              ; run_hi < clamp_right → no clamp
    ; Interpolate height at right screen edge
    LDA hmap_col
    DEC A
    AND #$1F
    TAY                       ; Y = inner column
    LDA interp_offset_r
    JSR interp_height
    LDA clamp_right
@sx_done:
    ; A = final sx for this vertex
    STA raster_x1             ; cache for V-chain endpoint
    ; Store (sx, sy, h_color, v_color) to v_buf
    LDY #0
    STA (v_ptr),Y
    INY
    LDA offset_tmp+1          ; final sy for this vertex
    STA raster_y1             ; cache for V-chain endpoint
    CMP grid_min_sy
    BCS @no_dirty_upd
    STA grid_min_sy
@no_dirty_upd:
    STA (v_ptr),Y
    ; --- Edge colours from LUT ---
    LDA offset_tmp
    AND #$E0                  ; keep bits 7-5
    LSR A
    LSR A
    LSR A
    LSR A                     ; A = (bits7-5) << 1
    TAX
    LDA offset_tmp
    AND #$1F                  ; height
    BNE :+
    INX                       ; sea_flag = 1
:   LDA edge_color_lut,X     ; packed: h in 4,2,0; v in 5,3,1
    TAX                       ; save packed in X
    AND #$15                  ; h_color
    STA offset_tmp            ; save for H-chain color update
    LDY #2
    STA (v_ptr),Y
    TXA
    LSR A
    AND #$15                  ; v_color
    LDY #3
    STA (v_ptr),Y

    ; --- Inline vertical chain drawing ---
    LDA proj_row
    BEQ @no_v_draw

    ; grid_ptr already points to prev row vertex (init at row start)

    ; Start point = previous row vertex
    LDY #0
    LDA (grid_ptr),Y          ; prev sx
    STA raster_x0
    INY
    LDA (grid_ptr),Y          ; prev sy
    STA raster_y0
    LDY #3
    LDA (grid_ptr),Y          ; prev v_color
    PHA                       ; save for draw_line

    ; Chain state: init_base on row 1, restore on row 2+
    LDX chain_state_idx
    LDA proj_row
    CMP #1
    BNE @v_restore
    JSR init_base             ; Y = sub_y
    BRA @v_ready
@v_restore:
    LDY chain_state,X
    LDA chain_state+1,X
    STA raster_base
    LDA chain_state+2,X
    STA raster_base+1
@v_ready:
    ; Endpoint = current vertex (raster_x1/y1 cached from v_buf write)

    ; Draw
    PLA                       ; v_color
    JSR draw_line             ; Y = sub_y

    ; Save chain state
    LDX chain_state_idx
    TYA
    STA chain_state,X
    LDA raster_base
    STA chain_state+1,X
    LDA raster_base+1
    STA chain_state+2,X

    ; Final pixel on last row
    LDA proj_row
    INC A
    CMP n_rows
    BNE @no_v_final
    LDA raster_x1
    STA raster_x0
    LSR A
    LDA (raster_base),Y
    BCS @vr_final
    AND #$D5
    ORA raster_color_left
    BRA @vs_final
@vr_final:
    AND #$EA
    ORA raster_color_right
@vs_final:
    STA (raster_base),Y
@no_v_final:
    ; Advance grid_ptr for next column's V-chain
    LDA grid_ptr
    CLC
    ADC #4
    STA grid_ptr
    BCC :+
    INC grid_ptr+1
:
@no_v_draw:

    ; Advance chain_state_idx
    LDA chain_state_idx
    CLC
    ADC #3
    STA chain_state_idx

    ; Advance heightmap column
    LDA hmap_col
    INC A
    AND #$1F
    STA hmap_col

    ; Advance v_ptr += 4
    LDA v_ptr
    CLC
    ADC #4
    STA v_ptr
    BCC @no_vpc
    INC v_ptr+1
@no_vpc:

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
@col_done:
    ; Save hmap_ptr for far-row Z interpolation
    LDA hmap_ptr
    STA prev_hmap_ptr
    LDA hmap_ptr+1
    STA prev_hmap_ptr+1

    ; Restore z_cam after near row adjustment
    LDA proj_row
    BNE @no_near_restore
    LDA interp_offset_near
    BEQ @no_near_restore
    STA offset_tmp
    LDA z_cam_lo
    SEC
    SBC offset_tmp
    STA z_cam_lo
    LDA z_cam_hi
    SBC #0
    STA z_cam_hi
@no_near_restore:
    BRA @next_row

@skip_row:
    ; Fill n_vtx vertices at (64, 159, 0, 0) in v_buf for behind-camera rows

    ; v_ptr = v_buf + v_row_offset[proj_row]
    LDX proj_row
    LDA v_row_offset_lo,X
    CLC
    ADC #<v_buf
    STA v_ptr
    LDA v_row_offset_hi,X
    ADC #>v_buf
    STA v_ptr+1
    LDX n_vtx
@skip_v:
    LDY #0
    LDA #64
    STA (v_ptr),Y
    INY
    LDA #159
    STA (v_ptr),Y
    INY
    LDA #0                    ; black colour (h_color)
    STA (v_ptr),Y
    INY
    STA (v_ptr),Y             ; black colour (v_color)
    ; advance v_ptr by 4
    LDA v_ptr
    CLC
    ADC #4
    STA v_ptr
    BCC @no_skip_vpc
    INC v_ptr+1
@no_skip_vpc:
    DEX
    BNE @skip_v

@next_row:
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
@proj_done:
    ; --- Post-projection: draw h-chains row by row (back-to-front) ---
    LDA n_rows
    SEC
    SBC #1
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

    LDA n_vtx
    SEC
    SBC #1
    STA seg_count
    JSR draw_h_row

    DEC proj_row
    BPL @h_row_loop
    RTS

; =====================================================================
; draw_h_row — Draw one horizontal chain from grid_ptr (4-byte stride)
; =====================================================================
; Input:  grid_ptr = row start, seg_count = segments (n_vtx - 1)

draw_h_row:
    LDY #0
    LDA (grid_ptr),Y          ; sx
    STA raster_x0
    INY
    LDA (grid_ptr),Y          ; sy
    STA raster_y0
    JSR init_base             ; Y = sub_y
@h_seg:
    STY saved_y
    LDY #2
    LDA (grid_ptr),Y          ; h_color
    STA saved_color
    ; Advance grid_ptr to next vertex
    LDA grid_ptr
    CLC
    ADC #4
    STA grid_ptr
    BCC :+
    INC grid_ptr+1
:   LDY #0
    LDA (grid_ptr),Y          ; endpoint sx
    STA raster_x1
    INY
    LDA (grid_ptr),Y          ; endpoint sy
    STA raster_y1
    LDY saved_y
    LDA saved_color
    JSR draw_line
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    DEC seg_count
    BNE @h_seg
    ; Final pixel
    LDA raster_x0
    LSR A                     ; bit 0 → carry
    LDA (raster_base),Y
    BCS @hr_final
    AND #$D5
    ORA raster_color_left
    BRA @hs_final
@hr_final:
    AND #$EA
    ORA raster_color_right
@hs_final:
    STA (raster_base),Y
    RTS

; =====================================================================
; set_hmap_ptr — Set hmap_ptr from heightmap row index
; =====================================================================
; Input:  A = hmap row index (0..31)
; Output: hmap_ptr set, X = input A (preserved for caller)

; =====================================================================
; ship_hmap_col — Convert ship world position axis to heightmap index
; =====================================================================
; Input:  Y = axis offset (0 = X, 4 = Z)
; Output: A = heightmap col/row (0..31)
ship_hmap_col:
    LDA obj_world_pos+OBJ_WORLD_SHIP,Y
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                     ; lo >> 6
    STA offset_tmp
    INY
    LDA obj_world_pos+OBJ_WORLD_SHIP,Y
    ASL A
    ASL A                     ; hi * 4
    CLC
    ADC offset_tmp
    AND #$1F
    RTS

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
    ASL A                     ; (hmap_z & 7) << 5
    CLC
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
    BRA @mcy_overflow         ; cam_y_hi >= 3: overflow
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
; Input:  A = diff (1..4), seg_count = offset (0..63)
; Output: A = LUT value

lut_lookup:
    DEC A                     ; diff - 1 (0..3)
    STA chain_idx
    LDA seg_count
    ASL A
    ASL A                     ; offset * 4
    ORA chain_idx             ; + (diff-1)
    TAX
    LDA interp_lut,X
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
; z_interp_vertex — Z-interpolate height in offset_tmp
; =====================================================================
; Interpolates offset_tmp's height (bits 0–4) between outer row (hmap_ptr)
; and inner row (interp_z_ptr) using z_interp_offset.
; Preserves colour bits (5–7) in offset_tmp.

z_interp_vertex:
    LDA z_interp_offset
    STA seg_count
    LDY hmap_col
    LDA (interp_z_ptr),Y      ; inner row cell byte
    AND #$1F                  ; h_inner_z
    STA chain_idx
    LDA offset_tmp
    AND #$1F                  ; h_outer_z
    JSR lerp_height            ; A = pre-scaled (0..248)
    RTS

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
    LDA recip_val
    STA math_b
    JSR umul8x8
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

