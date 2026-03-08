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
chain_count     = $A4       ; chains remaining
seg_count       = $A5       ; segments remaining in current chain
chain_idx       = $A6       ; byte offset within current chain
saved_y         = $A7       ; saved sub-row Y during chain iteration
saved_color     = $A8       ; colour for current segment (draw_chains) / prev_h_color
prev_h_color    = $A8       ; h-chain start colour during projection (shares saved_color)
clamp_left      = $A9       ; left edge screen x clamp (draw_grid)
chain_segs      = $AA       ; segments per chain (for draw_chains)
chain_stride    = $AB       ; bytes per chain (for draw_chains)
clamp_right     = $AC       ; right edge screen x clamp
; Shared (set in project, read in draw)
n_vtx           = $AD       ; vertices per row this frame
chain_y         = $AE       ; inline h-chain: saved sub-row Y during projection
n_rows          = $AF       ; vertex rows this frame
v_stride        = $B0       ; bytes per vertical chain (n_rows * 3)
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
v_buf: .res GRID_VTX_X * V_CHAIN_BYTES   ; vertical chains, column-major
.segment "CODE"

; ── Colour unpack table: 3-bit packed → MODE 2 right-pixel (bits 4,2,0) ──
; 0=black, 1=red, 2=green, 3=yellow, 4=blue, 5=magenta, 6=cyan, 7=white
color_unpack:
    .byte $00, $01, $04, $05, $10, $11, $14, $15

; Edge colour: index = sea*2 + bit_value
;   0=land,bit0 → yellow($05)  1=land,bit1 → green($04)
;   2=sea,bit0  → cyan($14)    3=sea,bit1  → blue($10)
grid_edge_lut:
    .byte $05, $04, $14, $10

; =====================================================================
; draw_grid — Project grid + draw h-chains inline + draw v-chains
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
    LDA cam_z_lo
    AND #$3F                  ; sub_z (0..63)
    CMP #$20
    BCS @z_wrap
    ; sub_z < $20: z_cam = (HALF_ROWS+1)*$40 - sub_z
    STA offset_tmp
    SEC
    LDA #<((HALF_ROWS + 1) * $40)
    SBC offset_tmp
    STA z_cam_lo
    LDA #>((HALF_ROWS + 1) * $40)
    SBC #0
    STA z_cam_hi
    BRA @z_done
@z_wrap:
    ; sub_z >= $20: z_cam = (HALF_ROWS+2)*$40 - sub_z
    STA offset_tmp
    SEC
    LDA #<((HALF_ROWS + 2) * $40)
    SBC offset_tmp
    STA z_cam_lo
    LDA #>((HALF_ROWS + 2) * $40)
    SBC #0
    STA z_cam_hi
@z_done:

    ; === Compute heightmap base indices ===
    ; base_x
    LDA cam_x_lo
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                     ; cam_x_lo >> 6 (0..3)
    STA offset_tmp
    LDA cam_x_hi
    ASL A
    ASL A                     ; cam_x_hi * 4
    CLC
    ADC offset_tmp
    SEC
    SBC #HALF_COLS
    STA base_x
    ; +1 if sub_x >= $20
    LDA cam_x_lo
    AND #$3F
    CMP #$20
    BCC @bx_done
    INC base_x
@bx_done:

    ; base_z
    LDA cam_z_lo
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A                     ; cam_z_lo >> 6 (0..3)
    STA offset_tmp
    LDA cam_z_hi
    ASL A
    ASL A                     ; cam_z_hi * 4
    CLC
    ADC offset_tmp
    SEC
    SBC #HALF_ROWS
    STA base_z
    ; +1 if sub_z >= $20
    LDA cam_z_lo
    AND #$3F
    CMP #$20
    BCC @bz_done
    INC base_z
@bz_done:

    ; === Determine n_vtx based on sub_x ===
    LDA cam_x_lo
    AND #$3F
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

    ; === Determine n_rows and v_stride based on sub_z ===
    LDA cam_z_lo
    AND #$3F
    CMP #$20
    BNE @full_z
    ; sub_z == $20: omit farthest row
    LDA #(GRID_VTX_Z - 1)
    STA n_rows
    LDA #((GRID_VTX_Z - 1) * 3)
    STA v_stride
    BRA @z_size_done
@full_z:
    LDA #GRID_VTX_Z
    STA n_rows
    LDA #V_CHAIN_BYTES
    STA v_stride
@z_size_done:

    ; === Compute interpolation offsets for edge height correction ===
    LDA cam_x_lo
    AND #$3F                  ; sub_x
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
    LDA cam_z_lo
    AND #$3F                  ; sub_z
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
    ; Near row projects at Z_NEAR_BOUND (z_cam adjusted to match)
    LDA #<(Z_NEAR_BOUND * 4)  ; = $80
    STA math_b
    LDA #>(Z_NEAR_BOUND * 4)  ; = $05
    STA math_a
    JSR urecip15
    LDA math_res_lo
    LSR A
    CLC
    ADC math_res_lo           ; recip * 1.5
    CLC
    ADC #80
    STA clamp_near_sy

    ; === Compute clamp_far_sy (far boundary screen-y) ===
    LDA #<(Z_FAR_BOUND * 4)
    STA math_b
    LDA #>(Z_FAR_BOUND * 4)
    STA math_a
    JSR urecip15
    LDA math_res_lo
    LSR A
    CLC
    ADC math_res_lo           ; recip * 1.5
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
    CLC
    ADC #1
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

    ; --- sy = 80 + recip * 3/2, clamped to [clamp_far_sy, clamp_near_sy] ---
    LSR A                     ; recip >> 1
    CLC
    ADC recip_val             ; recip * 1.5
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
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A                     ; step_lo = (recip & 3) << 6
    STA step_lo

    ; --- sx_running = $4000 - HALF_COLS*step ± sub_x*recip ---
    STZ run_lo
    LDA #64
    STA run_hi
    LDX #HALF_COLS
@sub_step:
    LDA run_lo
    SEC
    SBC step_lo
    STA run_lo
    LDA run_hi
    SBC step_hi
    STA run_hi
    DEX
    BNE @sub_step
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
    ; hmap_ptr = height_map + hmap_z * 32
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
    BCC @no_hmap_carry
    INC hmap_ptr+1
@no_hmap_carry:

    ; --- Heightmap next-row pointer (for vertical edge colour) ---
    TXA
    INC A
    AND #$1F
    TAX
    LSR A
    LSR A
    LSR A
    CLC
    ADC #>height_map
    STA hmap_next_ptr+1
    TXA
    AND #$07
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    CLC
    ADC #<height_map
    STA hmap_next_ptr
    BCC @no_hnext_carry
    INC hmap_next_ptr+1
@no_hnext_carry:

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
    CLC
    ADC #1
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
    LDA proj_row
    ASL A
    CLC
    ADC proj_row              ; A = proj_row * 3
    CLC
    ADC #<v_buf
    STA v_ptr
    LDA #>v_buf
    ADC #0                    ; propagate carry from lo add
    STA v_ptr+1

    ; --- Column loop: n_vtx vertices ---
    LDA n_vtx
    STA proj_col

@col_loop:
    ; --- Height lookup and sy adjustment ---
    LDY hmap_col
    LDA (hmap_ptr),Y
    STA offset_tmp            ; save full byte for color extraction
    ; Z-interpolate height if on a boundary row
    LDA z_interp_offset
    BEQ @no_z_interp
    JSR z_interp_vertex
@no_z_interp:
    LDA offset_tmp            ; re-load (may have been modified)
    AND #$1F                  ; height 0..31
    BEQ @use_sy_val           ; flat → use row's base sy

    ; Δsy = hi_byte(h*8 * recip) = h * recip / 32
    ASL A
    ASL A
    ASL A                     ; h * 8 (max 248, fits in byte)
    STA math_a
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
    STA grid_ptr              ; save sx (grid_ptr free during projection)
    ; Store (sx, sy) to v_buf
    LDY #0
    STA (v_ptr),Y
    INY
    LDA offset_tmp+1          ; final sy for this vertex
    CMP grid_min_sy
    BCS @no_dirty_upd
    STA grid_min_sy
@no_dirty_upd:
    STA (v_ptr),Y
    ; --- Horizontal edge colour ---
    LDX #0                    ; assume land
    LDA offset_tmp
    AND #$1F                  ; current height
    BNE @h_land               ; nonzero → definitely land
    ; Current height 0; check next column
    LDA hmap_col
    INC A
    AND #$1F
    TAY
    LDA (hmap_ptr),Y
    AND #$1F                  ; next column height
    BNE @h_land               ; nonzero → land edge
    LDX #2                    ; both zero → sea edge
@h_land:
    LDA offset_tmp
    AND #$40                  ; bit 6
    BEQ @h_bit_done
    INX
@h_bit_done:
    LDA grid_edge_lut,X
    STA grid_ptr+1            ; save h_color (grid_ptr+1 free during projection)

    ; --- Vertical edge colour (→ v_buf) ---
    LDX #0                    ; assume land
    LDA offset_tmp
    AND #$1F                  ; current height
    BNE @v_land               ; nonzero → definitely land
    ; Current height 0; check next row
    LDY hmap_col
    LDA (hmap_next_ptr),Y
    AND #$1F                  ; next row height
    BNE @v_land               ; nonzero → land edge
    LDX #2                    ; both zero → sea edge
@v_land:
    LDA offset_tmp
    ASL A                     ; bit 7 → carry
    BCC @v_bit_done
    INX
@v_bit_done:
    LDA grid_edge_lut,X
    LDY #2
    STA (v_ptr),Y

    ; --- Inline horizontal chain drawing ---
    LDX proj_col
    CPX n_vtx
    BEQ @first_h_vertex

    ; --- Middle or last vertex: draw segment from prev to current ---
    LDA grid_ptr              ; saved sx
    STA raster_x1
    LDA offset_tmp+1          ; sy
    STA raster_y1
    LDY chain_y
    LDA prev_h_color
    JSR draw_line
    ; Endpoint becomes startpoint
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    ; Check if last vertex (Y still valid from draw_line)
    LDX proj_col
    CPX #1
    BEQ @last_h_vertex
    ; Not last: save chain state
    STY chain_y
    LDA grid_ptr+1            ; current vertex's h_color
    STA prev_h_color
    BRA @h_chain_cont

@first_h_vertex:
    ; First vertex: initialize chain
    LDA grid_ptr              ; sx
    STA raster_x0
    LDA offset_tmp+1          ; sy
    STA raster_y0
    JSR init_base
    STY chain_y
    LDA grid_ptr+1            ; h_color
    STA prev_h_color
    BRA @h_chain_cont

@last_h_vertex:
    ; Draw final pixel of chain (Y = sub-row from draw_line)
    LDA raster_x0
    LSR A                     ; bit 0 → carry
    LDA (raster_base),Y
    BCS @right_final_h
    AND #$D5
    ORA raster_color_left
    BRA @store_final_h
@right_final_h:
    AND #$EA
    ORA raster_color_right
@store_final_h:
    STA (raster_base),Y

@h_chain_cont:
    ; Advance heightmap column
    LDA hmap_col
    INC A
    AND #$1F
    STA hmap_col

    ; Advance v_ptr += v_stride (no grid_ptr advance needed)
    LDA v_ptr
    CLC
    ADC v_stride
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
    ; Fill n_vtx vertices at (64, 159, black) in v_buf for behind-camera rows
    ; (horizontal chains drawn inline — nothing to fill)

    ; v_buf: stride v_stride per column (forward row order)
    LDA proj_row
    ASL A
    CLC
    ADC proj_row              ; proj_row * 3
    CLC
    ADC #<v_buf
    STA v_ptr
    LDA #>v_buf
    ADC #0                    ; propagate carry from lo add
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
    LDA #0                    ; black colour
    STA (v_ptr),Y
    ; advance v_ptr by v_stride
    LDA v_ptr
    CLC
    ADC v_stride
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
    LDA #<v_buf
    STA grid_ptr
    LDA #>v_buf
    STA grid_ptr+1
    LDA n_vtx
    STA chain_count
    LDA n_rows
    SEC
    SBC #1
    STA chain_segs
    LDA v_stride
    STA chain_stride
    JMP draw_chains

; =====================================================================
; lut_lookup — Look up interpolation LUT value
; =====================================================================
; Input:  A = diff (1..4), seg_count = offset (0..63)
; Output: A = LUT value

lut_lookup:
    DEC A                     ; diff - 1 (0..3)
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A                     ; (diff-1) * 64
    ORA seg_count             ; + offset
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
    LSR A
    LSR A
    LSR A                     ; → height units (0..31)
    STA chain_idx              ; temp
    LDA offset_tmp
    AND #$E0                  ; preserve colour bits
    ORA chain_idx
    STA offset_tmp
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

draw_chains:
@chain_loop:
    ; Load first point of chain
    LDY #0
    LDA (grid_ptr),Y
    STA raster_x0
    INY
    LDA (grid_ptr),Y
    STA raster_y0
    JSR init_base           ; set raster_base, Y for start point
    LDA #3
    STA chain_idx
    LDA chain_segs
    STA seg_count

@seg_loop:
    ; Save sub-row Y from previous segment / init_base
    STY saved_y
    ; Load colour for this segment (at startpoint's colour byte)
    LDY chain_idx
    DEY                     ; chain_idx - 1 = colour offset
    LDA (grid_ptr),Y
    STA saved_color
    INY
    ; Load next endpoint
    LDA (grid_ptr),Y
    STA raster_x1
    INY
    LDA (grid_ptr),Y
    STA raster_y1
    INY
    INY                     ; skip endpoint's colour byte
    STY chain_idx
    ; Restore sub-row Y before draw_line
    LDY saved_y
    LDA saved_color
    JSR draw_line           ; draw segment, chaining state
    ; Endpoint becomes start of next segment
    LDA raster_x1
    STA raster_x0
    LDA raster_y1
    STA raster_y0
    DEC seg_count
    BNE @seg_loop

    ; Draw final pixel of chain
    LDA raster_x0
    LSR A                   ; bit 0 → carry
    LDA (raster_base),Y
    BCS @right_final
    AND #$D5
    ORA raster_color_left
    BRA @store_final
@right_final:
    AND #$EA
    ORA raster_color_right
@store_final:
    STA (raster_base),Y

    ; Advance to next chain
    LDA grid_ptr
    CLC
    ADC chain_stride
    STA grid_ptr
    BCC @no_carry
    INC grid_ptr+1
@no_carry:
    DEC chain_count
    BNE @chain_loop
    RTS
