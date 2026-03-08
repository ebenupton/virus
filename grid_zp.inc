; grid_zp.inc — Grid dimension constants
;
; Include-guarded: safe to .include from multiple files.
; No ZP variables — all grid workspace is declared in grid.s.

.ifndef GRID_ZP_INC
GRID_ZP_INC = 1

; ── Grid dimensions (cells, not vertices) ───────────────────────────
GRID_COLS       = 10            ; cells across (X direction)
GRID_ROWS       = 8             ; cells down (Z direction)
GRID_VTX_X      = GRID_COLS + 1 ; vertices per row
GRID_VTX_Z      = GRID_ROWS + 1 ; vertices per column (= number of rows)
HALF_COLS       = GRID_COLS / 2  ; half-width in cells
HALF_ROWS       = GRID_ROWS / 2  ; half-depth in cells
V_CHAIN_BYTES   = GRID_VTX_Z * 3 ; bytes per vertical chain

; ── Dirty-top output (set by draw_grid, read by game.s) ──────────
grid_min_sy     = $BE           ; minimum screen Y across all grid vertices

; ── Derived geometry constants ──────────────────────────────────────
HALF_GRID_X     = (GRID_COLS - 1) * $20   ; X half-extent in 8.8
HALF_GRID_X_LO  = HALF_GRID_X & $FF       ; low byte
HALF_GRID_X_HI  = HALF_GRID_X >> 8        ; high byte
HALF_GRID_Z     = (GRID_ROWS - 1) * $20   ; Z half-extent in 8.8
Z_GRID_CENTER   = (HALF_ROWS + 1 + HALF_ROWS) * $40
Z_NEAR_BOUND    = Z_GRID_CENTER - HALF_GRID_Z
Z_FAR_BOUND     = Z_GRID_CENTER + HALF_GRID_Z

.endif
