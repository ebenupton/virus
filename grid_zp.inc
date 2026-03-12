; grid_zp.inc — Grid dimension constants
;
; Include-guarded: safe to .include from multiple files.
; No ZP variables — all grid workspace is declared in grid.s.

.ifndef GRID_ZP_INC
GRID_ZP_INC = 1

; ── Grid dimensions (cells, not vertices) ───────────────────────────
GRID_COLS       = 8             ; cells across (X direction)
GRID_ROWS       = 6             ; cells down (Z direction)
GRID_VTX_X      = GRID_COLS + 1 ; vertices per row
GRID_VTX_Z      = GRID_ROWS + 1 ; vertices per column (= number of rows)
HALF_COLS       = GRID_COLS / 2  ; half-width in cells
HALF_ROWS       = GRID_ROWS / 2  ; half-depth in cells
ROW_STRIDE      = GRID_VTX_X * 4  ; bytes per vertex row in v_buf

; ── Outputs (set by project_grid, read by game.s) ────────────────
grid_min_sy     = $BE           ; minimum screen Y across all grid vertices
terrain_y       = $BF           ; terrain height at ship pos (height*8, 8.8 lo)

; ── Derived geometry constants ──────────────────────────────────────
HALF_GRID_X     = (GRID_COLS - 1) * $20   ; X half-extent in 8.8
HALF_GRID_X_LO  = HALF_GRID_X & $FF       ; low byte
HALF_GRID_X_HI  = HALF_GRID_X >> 8        ; high byte
HALF_GRID_Z     = (GRID_ROWS - 1) * $20   ; Z half-extent in 8.8
Z_GRID_CENTER   = $0280          ; CAM_Z_BEHIND + $40 (grid pushed out one cell)
Z_NEAR_BOUND    = Z_GRID_CENTER - HALF_GRID_Z
Z_FAR_BOUND     = Z_GRID_CENTER + HALF_GRID_Z

.endif
