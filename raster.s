; raster.s — Bresenham line rasterizer for BBC Micro MODE 2
;
; Provides: draw_line, init_base
; Requires: raster_zp.inc zero-page variables, screen_page set by caller
;
; ── MODE 2 screen layout ──────────────────────────────────────────────
; 128×160 pixels, 4bpp (2 pixels per byte), 64 byte-columns.
; Memory is organised in character rows of 512 bytes (64 cols × 8 rows).
; Within a cell, bytes are consecutive scan-lines (sub-row 0..7).
;
;   addr = screen_base + char_row*512 + byte_col*8 + sub_row
;
; Each byte packs a left pixel (even X) and a right pixel (odd X):
;   Left pixel:  bits 5,3,1  — colour 7 → $2A
;   Right pixel: bits 4,2,0  — colour 7 → $15
;   Both pixels: $2A | $15 = $3F
; The AND mask to clear a pixel position is the bitwise complement:
;   Clear left:  $D5          Clear right: $EA
;
; ── Coordinate system ─────────────────────────────────────────────────
; X: 0..127 (left to right)   Y: 0..159 (top to bottom)
;
; ── Chaining model ────────────────────────────────────────────────────
; draw_line draws pixels from (x0,y0) up to but NOT including (x1,y1).
; On return, base/Y are positioned at (x1,y1), ready for the next
; segment or a final pixel plot.  Caller must:
;   1. JSR init_base for the first point of a chain
;   2. JSR draw_line for each segment (Y preserved through setup)
;   3. Copy x1→x0, y1→y0 between segments
;   4. Plot the final pixel of the chain using (base),Y
;
; ── Architectural overview ────────────────────────────────────────────
;
; BRESENHAM ERROR TRACKING
;   The Bresenham error accumulator lives in the X register throughout
;   the inner loops — never stored to zero page.  This saves 6 cycles
;   per pixel (3 for LDA zp + 3 for STA zp) at the cost of requiring
;   TAX/TXA transfers around pixel drawing and address arithmetic.
;
;   Error starts at (delta_major - delta_minor) and is decremented by
;   delta_minor each pixel.  When it borrows (C=0 after SBC), we step
;   the minor axis and add delta_major to restore it.  The initial
;   value and SEC/ADC arithmetic keep the error in [0, delta_major).
;
; CARRY CHAIN
;   The SBC-based error update requires C=1 on entry.  Rather than
;   executing SEC every iteration (2 cycles), we maintain C=1 as an
;   invariant across the loop:
;
;   - SBC delta_minor with no borrow: C=1 preserved, chain continues.
;   - SBC delta_minor with borrow (C=0): ADC delta_major always
;     produces C=1, because the unsigned-wrapped error (>=256-delta_minor)
;     plus delta_major (>=delta_minor) always exceeds 255.
;   - Column advance via SBC #$F8 (=add 8, C=1) or ADC #$08 (C=0):
;     may produce C=0 or C=1; SEC restores C=1 on the common path.
;   - Y-down row cross (INY/CPY #8): CPY leaves C=0 when Y<8 (common),
;     C=1 when Y=8 (row cross, rare).  The common path needs SEC.
;   - Y-up row cross (DEY/BMI): DEY does not affect carry, so C=1 is
;     preserved from the preceding SBC or ADC.  This eliminates SEC
;     entirely from the Y-up hot path — a 2-cycle saving per pixel.
;
; STEEP VS SHALLOW
;   Lines are classified by slope:
;   - Steep (|dy| > |dx|): major axis is Y, one pixel per iteration.
;     8 variants indexed by {x0_parity, x_direction, y_direction}.
;   - Shallow (|dx| >= |dy|): major axis is X, process pixel PAIRS.
;     16 variants indexed by {x0_parity, ~count_parity, x_dir, y_dir}.
;
; TWO-PIXEL PAIRING (shallow only)
;   Because MODE 2 packs two pixels per byte, shallow lines process
;   pairs: a left pixel and a right pixel that share the same byte
;   address.  Three sub-cases per pair, based on Bresenham error:
;
;   - Fast-fast (ff): neither pixel Y-steps.  Both pixels occupy the
;     same byte, so we write color_both in a single STA — no
;     read-modify-write needed.  This is the fastest path.
;   - Slow: the first pixel Y-steps (moves to a new scan-line before
;     drawing).  Both pixels require read-modify-write.
;   - Fast-slow: the first pixel is fast, the second Y-steps.  We
;     write color_both for the first pixel's byte, then the second
;     pixel is read-modify-write on the next row.
;
;   Each pair also includes a column advance (base ±= 8) and a
;   pixel_count decrement.  The DEC+BNE/BEQ test can be placed either
;   between the two pixels ("mid") or after the column advance ("end").
;   Whichever position is chosen, the other position's 5-cycle
;   DEC+branch is eliminated entirely.  The dispatch table selects
;   end vs mid based on x0_parity XOR ~count_parity, ensuring the
;   pixel count comes out exactly right for each entry point (_l or _r).
;
; BRANCH OPTIMISATION
;   On the 65C02, a taken branch costs 3 cycles vs 2 for not-taken.
;   Every conditional branch is arranged so the common case falls
;   through (not-taken, 2 cycles) and the rare handler is "outlined"
;   after the fall-through block, jumping back with BRA (+2 bytes).
;
;   Applied to: Y-up row cross (DEY/BMI, row cross 1/8), Y-down row
;   cross (INY/CPY/BEQ, 1/8), column page cross (BCS/BCC, ~1/32),
;   and Bresenham Y-step (BCC, workload-dependent but typically <50%).
;
; PAGE/ROW CROSSING
;   Row cross: every 8 Y-steps, base changes by ±512 (two INC/DEC of
;   base+1) and Y wraps (0↔7).  Occurs on 1/8 of Y-steps.
;   Page cross: every 32 column steps, base+1 changes by ±1.  Occurs
;   on ~1/32 of column steps.  Handlers are outlined (rare path taken).
;
;   Right-moving page handlers that share the DEC pixel_count + BNE +
;   RTS tail are deduplicated: the page handler BRAs to a _dec label
;   after the SEC, saving 4 bytes per instance at +3 cycles on the
;   rare page-cross path.
;
; STEEP X-STEP AND PIXEL TOGGLING
;   Steep lines alternate between left-pixel and right-pixel phases.
;   When no X-step occurs, the pixel parity is unchanged and the loop
;   iterates within the same phase.  On X-step (error borrows), the
;   code jumps to the paired phase's Y-step handler, toggling parity.
;
;   Y-down (tdr/tdl): X-step uses BRA to the paired ystep label, which
;   is a remote branch.  The column advance chains C=1 from
;   ADC delta_major into ADC #$07 (= add 8, since C=1).
;
;   Y-up (tur/tul): X-step inlines the paired phase's Y-step and
;   loop-back, eliminating the BRA to a remote target.  This costs
;   ~20 bytes per pair but saves 3 cycles on every X-step.  The
;   column advance also chains C=1 into ADC #$07 / ADC #$F7.
;
; REGISTER CONVENTIONS
;   Inside loops:  X = Bresenham error accumulator
;                  Y = sub-row within current character cell (0..7)
;                  A = scratch (pixel AND/ORA, error arithmetic)
;   Zero page:     base    = screen pointer (2 bytes)
;                  delta_minor, delta_major = Bresenham axis deltas
;                  pixel_count = pixels (steep) or pairs (shallow)
;                  color_left, color_right, color_both = colour masks
;
; LABEL CONVENTIONS
;   Public entry points and all rasterizer loop labels are global.
;   draw_line and init_base use @local labels for internal branches.
;
;   Shallow loop labels follow the pattern:
;     {s}{d|u}{r|l}_end|mid_{l|r}  — entry points
;     {s}{d|u}{r|l}_end_{ff|sbc2|fs|slow}_{...}  — internal labels
;   where s=shallow, d=down, u=up, r=right, l=left, ff=fast-fast,
;   sbc2=second-pixel SBC path, fs=fast-slow.
;
;   Steep loop labels follow: {t}{d|u}{r|l}_{l|r}_{px|ystep|...}
;   where t=steep (tall).
;
; =====================================================================

.include "raster_zp.inc"

; =====================================================================
; Dispatch tables
; =====================================================================

; steep_tbl — 8 entries, indexed by {x0_par, x_left, y_up}
; Entry point receives A = initial error, C=1, Y = sub-row.
steep_tbl:
    .word tdr_l              ;  0: left-pixel,  right-moving, down
    .word tur_l              ;  1: left-pixel,  right-moving, up
    .word tdl_l              ;  2: left-pixel,  left-moving,  down
    .word tul_l              ;  3: left-pixel,  left-moving,  up
    .word tdr_r              ;  4: right-pixel, right-moving, down
    .word tur_r              ;  5: right-pixel, right-moving, up
    .word tdl_r              ;  6: right-pixel, left-moving,  down
    .word tul_r              ;  7: right-pixel, left-moving,  up

; shallow_tbl — 16 entries, indexed by {x0_par, ~count_par, x_left, y_up}
; The end/mid selection ensures pixel counts align with entry parity:
;   Right-moving: XOR(x0_par, ~count_par) = 1 → end, 0 → mid
;   Left-moving:  XOR(x0_par, ~count_par) = 0 → end, 1 → mid
shallow_tbl:
    .word sdr_mid_l          ;  0: par=0, ~cp=0, right, down  XOR=0→mid
    .word sur_mid_l          ;  1: par=0, ~cp=0, right, up    XOR=0→mid
    .word sdl_end_l          ;  2: par=0, ~cp=0, left,  down  XOR=0→end
    .word sul_end_l          ;  3: par=0, ~cp=0, left,  up    XOR=0→end
    .word sdr_end_l          ;  4: par=0, ~cp=1, right, down  XOR=1→end
    .word sur_end_l          ;  5: par=0, ~cp=1, right, up    XOR=1→end
    .word sdl_mid_l          ;  6: par=0, ~cp=1, left,  down  XOR=1→mid
    .word sul_mid_l          ;  7: par=0, ~cp=1, left,  up    XOR=1→mid
    .word sdr_end_r          ;  8: par=1, ~cp=0, right, down  XOR=1→end
    .word sur_end_r          ;  9: par=1, ~cp=0, right, up    XOR=1→end
    .word sdl_mid_r          ; 10: par=1, ~cp=0, left,  down  XOR=1→mid
    .word sul_mid_r          ; 11: par=1, ~cp=0, left,  up    XOR=1→mid
    .word sdr_mid_r          ; 12: par=1, ~cp=1, right, down  XOR=0→mid
    .word sur_mid_r          ; 13: par=1, ~cp=1, right, up    XOR=0→mid
    .word sdl_end_r          ; 14: par=1, ~cp=1, left,  down  XOR=0→end
    .word sul_end_r          ; 15: par=1, ~cp=1, left,  up    XOR=0→end

; =====================================================================
; draw_line — Draw a Bresenham line from (x0,y0) towards (x1,y1)
;
; Inputs:   A            right-pixel colour mask (bits 4,2,0)
;           x0, y0       start pixel (screen state must match via
;                         init_base or previous draw_line)
;           x1, y1       end pixel (not plotted — chaining endpoint)
;           base          screen cell pointer (from init_base / prior call)
;           Y             sub-row (0..7) within current cell
;
; Outputs:  base, Y positioned at (x1, y1) for chaining
;
; Clobbers: A, X
;
; Notes:    Skips the endpoint pixel — caller chains or plots it.
;           Setup uses X for |dx| so Y (sub-row) is never disturbed.
;           Zero-length lines (x0==x1 && y0==y1) return immediately.
; =====================================================================

draw_line:
    ; --- Derive all three colour masks from the right-pixel mask ---
    ; color_left = color_right << 1 (shifts bits 4,2,0 to bits 5,3,1)
    ; color_both = color_left | color_right (both pixels in one byte)
    STA color_right
    ASL A
    STA color_left
    ORA color_right
    STA color_both

    ; --- Compute |dx|, hold in X (Y untouched throughout setup) ---
    LDA x1
    SEC
    SBC x0
    BCS @dx_pos
    EOR #$FF                ; negate: complement...
    INC A                   ; ...and increment
    SEC                     ; restore C=1 (was C=0 from SBC borrow)
@dx_pos:
    TAX                     ; X = |dx|, C=1

    ; --- Compute |dy| (C=1 from above, either path) ---
    LDA y0
    SBC y1                  ; C=1 from SEC or BCS path
    BCS @dy_pos
    EOR #$FF
    INC A                   ; INC A does not affect carry
@dy_pos:
    ; A = |dy|, X = |dx|, Y = sub-row (preserved)

    ; --- Zero-length check and steep/shallow routing ---
    BNE @has_len            ; |dy| != 0 → at least one axis nonzero
    CPX #0
    BEQ @zero_line          ; both zero → nothing to draw

@has_len:
    STA delta_minor         ; tentatively assign |dy| as minor axis
    CPX delta_minor         ; compare |dx| vs |dy|
    BCS @shallow            ; C=1: |dx| >= |dy| → shallow

    ; --- STEEP: |dy| > |dx|, major axis is Y ---
    STX delta_minor         ; correct: minor = |dx|
    STA pixel_count         ; one pixel per Y-step
    STA delta_major

    ; Build 3-bit index: {x0_par, x_left, y_up}
    LDA x0
    TAX
    AND #$01                ; bit 0: starting pixel parity
    CPX x1                  ; C=1 if x0 >= x1 (moving left)
    ROL A                   ; shift in x_left flag
    LDX y0
    CPX y1                  ; C=1 if y0 >= y1 (moving up)
    ROL A                   ; shift in y_up flag
    ASL A                   ; ×2 for word-sized table entries
    TAX

    LDA delta_major
    SEC
    SBC delta_minor         ; initial error = delta_major - delta_minor
    JMP (steep_tbl,X)       ; C=1 from SBC (delta_major > delta_minor)

@shallow:
    ; --- SHALLOW: |dx| >= |dy|, major axis is X ---
    STX delta_major
    ; delta_minor already holds |dy| from the tentative assignment

    ; pixel_count = ceil(|dx| / 2) = number of pixel pairs
    TXA                     ; A = |dx|
    INC A
    LSR A                   ; A = (|dx|+1)/2, C = (|dx|+1) bit 0
    STA pixel_count         ; C = ~count_parity (preserved below)

    ; Build 4-bit index: {x0_par, ~count_par, x_left, y_up}
    ; C = ~count_parity, preserved through LDA/TAX/AND (none affect C)
    LDA x0
    TAX
    AND #$01                ; bit 0: starting pixel parity
    ROL A                   ; shift in ~count_par from C; C←0
    CPX x1                  ; C=1 if moving left
    ROL A                   ; shift in x_left
    LDX y0
    CPX y1                  ; C=1 if moving up
    ROL A                   ; shift in y_up
    ASL A                   ; ×2 for word-sized table entries
    TAX

    LDA delta_major
    SEC
    SBC delta_minor         ; initial error, C=1 (delta_major >= delta_minor)
    JMP (shallow_tbl,X)

@zero_line:
    RTS

; =====================================================================
; SHALLOW LOOPS
;
; Each of the 4 direction combinations (sdr, sdl, sur, sul) has an
; "end" variant and a "mid" variant, each with _l and _r entry points.
; See the architectural overview for the end/mid pixel-count logic.
;
; Carry state on loop entry: C=1 (from dispatch SBC or loop-back SEC).
; The first SBC delta_minor consumes this carry.
;
; Column advance/retreat arithmetic:
;   Right-moving with C=1: SBC #$F8 = base + 8  (since -(-8) = +8)
;   Right-moving with C=0: ADC #$08 = base + 8
;   Left-moving  with C=1: SBC #$08 = base - 8
;   Left-moving  with C=0: ADC #$F8 = base - 8  (since +(-8) = -8)
; =====================================================================

; === sdr: shallow, Y-down, X-right — exits at end =====================

sdr_end_l:
    TAX
sdr_end_loop:
    TXA                             ; A = error, C=1 (invariant)
sdr_end_sbc1:
    SBC delta_minor                 ; C=1: first pixel Bresenham test
    BCC sdr_end_slow                ; borrow → first pixel Y-steps
    SBC delta_minor                 ; C=1: second pixel Bresenham test
    BCC sdr_end_fastslow            ; borrow → second pixel Y-steps

    ; --- Fast-fast: neither pixel Y-steps ---
    ; Both pixels share the same byte, so write color_both directly
    ; (no read-modify-write needed).  C=1 from second SBC.
    TAX
    LDA color_both
    STA (base),Y
    ; Column advance: base += 8.  SBC #$F8 with C=1 = add 8.
    LDA base
    SBC #$F8                        ; C=1 from SBC chain
    STA base
    BCS sdr_end_ff_page             ; C=1 after SBC → page cross (rare)
    SEC                             ; restore C=1 (was C=0, no page cross)
sdr_end_ff_dec:
    DEC pixel_count
    BNE sdr_end_loop
    RTS
sdr_end_ff_page:
    INC base+1                      ; C=1 preserved (INC doesn't touch C)
    BRA sdr_end_ff_dec

sdr_end_r:
    TAX
    LDA (base),Y
    AND #$EA                        ; clear right-pixel bits
    ORA color_right
    STA (base),Y
    TXA
    BRA sdr_end_sbc2

    ; --- Second pixel, no Y-step (C=1 from SBC) ---
sdr_end_sbc2:
    SBC delta_minor
    BCC sdr_end_sbc2_ystep          ; borrow → Y-step on second pixel
    ; No Y-step.  Column advance via SBC (C=1).
    TAX
    LDA base
    SBC #$F8                        ; C=1 from SBC no-borrow
    STA base
    BCS sdr_end_sbc2_page           ; page cross (rare)
sdr_end_sbc2_sec:
    SEC                             ; restore C=1 for next iteration
sdr_end_sbc2_dec:
    DEC pixel_count
    BNE sdr_end_loop
    RTS
sdr_end_sbc2_page:
    INC base+1                      ; C=1 preserved
    BRA sdr_end_sbc2_dec

    ; --- Second pixel, Y-step (C=0 from SBC borrow) ---
sdr_end_sbc2_ystep:
    ADC delta_major                 ; C=0 in; C=1 out (always: see header)
    INY                             ; Y-step down
    CPY #8                          ; C=0 if Y<8 (common), C=1 if Y=8
    BEQ sdr_end_sbc2_row            ; row cross (1/8, rare)
sdr_end_sbc2_norow:
    ; Column advance via ADC (C=0 from CPY with Y<8).
    TAX
    LDA base
    ADC #$08                        ; C=0 from CPY
    STA base
    BCS sdr_end_sbc2_page           ; page cross → share handler
    BRA sdr_end_sbc2_sec            ; no page → restore C=1
sdr_end_sbc2_row:
    INC base+1
    INC base+1                      ; base += 512 (next character row)
    LDY #0                          ; wrap sub-row
    CLC                             ; C=1 from CPY #8 match → clear for ADC
    BRA sdr_end_sbc2_norow

    ; --- Fast-slow: first pixel fast, second Y-steps (C=0) ---
sdr_end_fastslow:
    ADC delta_major                 ; C=0 in; C=1 out (always)
    TAX
    LDA color_both                  ; first pixel was fast → write both
    STA (base),Y
    INY                             ; Y-step down for second pixel
    CPY #8                          ; C=0 if Y<8
    BEQ sdr_end_fs_row              ; row cross (rare)
sdr_end_fs_norow:
    ; Column advance via ADC (C=0 from CPY with Y<8).
    LDA base
    ADC #$08                        ; C=0 from CPY
    STA base
    BCS sdr_end_fs_page             ; page cross (rare)
    BRA sdr_end_sbc2_sec            ; → SEC, DEC, loop
sdr_end_fs_page:
    INC base+1
    BRA sdr_end_sbc2_sec
sdr_end_fs_row:
    INC base+1
    INC base+1
    LDY #0
    CLC                             ; C=1 from CPY → clear for ADC
    BRA sdr_end_fs_norow

    ; --- Slow: first pixel Y-steps, both read-modify-write ---
sdr_end_slow:
    ADC delta_major                 ; C=0 in; C=1 out (always)
    TAX
    ; Draw left pixel at current position (first pixel of pair)
    LDA (base),Y
    AND #$D5                        ; clear left-pixel bits
    ORA color_left
    STA (base),Y
    ; Y-step down
    INY
    CPY #8                          ; C=0 if Y<8, C=1 if Y=8
    BEQ sdr_end_slow_row            ; row cross (rare)
    SEC                             ; restore C=1 for second pixel's SBC
sdr_end_slow_norow:
    ; Draw right pixel at new Y position (same byte column)
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    TXA                             ; restore error; C=1 from SEC or CPY
    BRA sdr_end_sbc2                ; → second pixel SBC, column advance
sdr_end_slow_row:
    INC base+1
    INC base+1
    LDY #0
    BRA sdr_end_slow_norow          ; C=1 from CPY #8 match

; === sdr: shallow, Y-down, X-right — exits in middle ==================
; Draws pc-1 pairs via the _end loop, then one trailing left pixel.

sdr_mid_l:
    TAX                             ; save error (DEC doesn't affect A/X)
    DEC pixel_count                 ; pc-1 pairs for _end loop
    BEQ sdr_trail                   ; pc was 1 → only trailing pixel
    JSR sdr_end_sbc1                ; enter mid-loop (A=error, skip TAX/TXA)
sdr_trail:
    ; Draw trailing left pixel
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    ; One final Bresenham step to position at endpoint
    TXA
    SBC delta_minor                 ; C=1 from _end loop exit or dispatch
    BCS sdr_trail_done              ; no Y-step → done
    ADC delta_major                 ; C=0 in; C=1 out
    INY
    CPY #8
    BNE sdr_trail_done              ; no row cross → done
    INC base+1
    INC base+1
    LDY #0
sdr_trail_done:
    RTS

sdr_mid_r:
    JSR sdr_end_r                   ; draw 2*pc-1 pixels; X=error, C=1
    BRA sdr_trail

; === sdl: shallow, Y-down, X-left — exits at end ======================

sdl_end_r:
    TAX
sdl_end_loop:
    TXA                             ; A = error, C=1 (invariant)
sdl_end_sbc1:
    SBC delta_minor
    BCC sdl_end_slow
    SBC delta_minor
    BCC sdl_end_fastslow

    ; --- Fast-fast: C=1, column retreat ---
    TAX
    LDA color_both
    STA (base),Y
    ; Column retreat: base -= 8.  SBC #$08 with C=1.
    LDA base
    SBC #$08                        ; C=1 from SBC chain
    STA base
    BCC sdl_end_ff_borrow           ; C=0 → page borrow (rare)
sdl_end_ff_nopg:
    DEC pixel_count
    BNE sdl_end_loop
    RTS
sdl_end_ff_borrow:
    DEC base+1
    SEC                             ; restore C=1 after borrow
    BRA sdl_end_ff_nopg

sdl_end_l:
    TAX
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    TXA
    BRA sdl_end_sbc2

    ; --- Second pixel, no Y-step (C=1) ---
sdl_end_sbc2:
    SBC delta_minor
    BCC sdl_end_sbc2_ystep
    TAX
    LDA base
    SBC #$08                        ; C=1 from SBC no-borrow
    STA base
    BCC sdl_end_sbc2_borrow         ; page borrow (rare)
sdl_end_sbc2_nopg:
    DEC pixel_count
    BNE sdl_end_loop
    RTS
sdl_end_sbc2_borrow:
    DEC base+1
    SEC
    BRA sdl_end_sbc2_nopg

    ; --- Second pixel, Y-step (C=0 from SBC borrow) ---
sdl_end_sbc2_ystep:
    ADC delta_major                 ; C=0 in; C=1 out (always)
    INY
    CPY #8                          ; C=0 if Y<8
    BEQ sdl_end_sbc2_row
sdl_end_sbc2_norow:
    ; Column retreat via ADC #$F8 (C=0 from CPY): base + $F8 = base - 8
    TAX
    LDA base
    ADC #$F8                        ; C=0 from CPY
    STA base
    BCS sdl_end_sbc2_nopg           ; C=1 → no borrow (common)
    BRA sdl_end_sbc2_borrow         ; C=0 → borrow (rare)
sdl_end_sbc2_row:
    INC base+1
    INC base+1
    LDY #0
    CLC                             ; C=1 from CPY → clear for ADC
    BRA sdl_end_sbc2_norow

    ; --- Fast-slow (C=0 from second SBC borrow) ---
sdl_end_fastslow:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    LDA color_both
    STA (base),Y
    INY
    CPY #8                          ; C=0 if Y<8
    BEQ sdl_end_fs_row
sdl_end_fs_norow:
    ; Column retreat via ADC #$F8 (C=0 from CPY).
    LDA base
    ADC #$F8                        ; C=0 from CPY
    STA base
    BCC sdl_end_fs_borrow           ; page borrow (rare)
sdl_end_fs_nopg:
    DEC pixel_count
    BNE sdl_end_loop
    RTS
sdl_end_fs_borrow:
    DEC base+1
    SEC
    BRA sdl_end_fs_nopg

    ; --- Slow: first pixel Y-steps ---
sdl_end_slow:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    ; Left-moving: first pixel is right, second is left
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    INY
    CPY #8
    BEQ sdl_end_slow_row
    SEC                             ; restore C=1 for second pixel SBC
sdl_end_slow_norow:
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    TXA                             ; C=1 from SEC or CPY
    BRA sdl_end_sbc2
sdl_end_slow_row:
    INC base+1
    INC base+1
    LDY #0
    BRA sdl_end_slow_norow          ; C=1 from CPY #8 match
sdl_end_fs_row:
    INC base+1
    INC base+1
    LDY #0
    CLC                             ; C=1 from CPY → clear for ADC
    BRA sdl_end_fs_norow

; === sdl: shallow, Y-down, X-left — exits in middle ===================
; Draws pc-1 pairs via _end, then one trailing right pixel.

sdl_mid_r:
    TAX
    DEC pixel_count
    BEQ sdl_trail
    JSR sdl_end_sbc1
sdl_trail:
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    ; Final Bresenham step to position at endpoint
    TXA
    SBC delta_minor                 ; C=1 from _end exit or dispatch
    BCS sdl_trail_done
    ADC delta_major
    INY
    CPY #8
    BNE sdl_trail_done
    INC base+1
    INC base+1
    LDY #0
sdl_trail_done:
    RTS

sdl_mid_l:
    JSR sdl_end_l
    BRA sdl_trail

; === sur: shallow, Y-up, X-right — exits at end =======================
; Y-up variant: DEY/BMI instead of INY/CPY.  DEY preserves carry,
; eliminating SEC from the common (no row cross) path.

sur_end_l:
    TAX
sur_end_loop:
    TXA                             ; A = error, C=1
sur_end_sbc1:
    SBC delta_minor
    BCC sur_end_slow
    SBC delta_minor
    BCC sur_end_fastslow

    ; --- Fast-fast: C=1, column advance ---
    TAX
    LDA color_both
    STA (base),Y
    LDA base
    SBC #$F8                        ; C=1: base += 8
    STA base
    BCS sur_end_ff_page             ; page cross (rare)
    SEC
sur_end_ff_dec:
    DEC pixel_count
    BNE sur_end_loop
    RTS
sur_end_ff_page:
    INC base+1                      ; C=1 preserved
    BRA sur_end_ff_dec

sur_end_r:
    TAX
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    TXA
    BRA sur_end_sbc2

    ; --- Second pixel, no Y-step (C=1) ---
sur_end_sbc2:
    SBC delta_minor
    BCC sur_end_sbc2_ystep
    TAX
    LDA base
    SBC #$F8                        ; C=1: base += 8
    STA base
    BCS sur_end_sbc2_page
sur_end_sbc2_sec:
    SEC
sur_end_sbc2_dec:
    DEC pixel_count
    BNE sur_end_loop
    RTS
sur_end_sbc2_page:
    INC base+1
    BRA sur_end_sbc2_dec

    ; --- Second pixel, Y-step up (C=0 from SBC borrow) ---
sur_end_sbc2_ystep:
    ADC delta_major                 ; C=0 in; C=1 out (always)
    DEY                             ; Y-step up; C=1 preserved (DEY ≠ carry)
    BMI sur_end_sbc2_row            ; Y<0 → row cross (rare, 1/8)
sur_end_sbc2_norow:
    ; Column advance via SBC (C=1 preserved through DEY/BMI).
    TAX
    LDA base
    SBC #$F8                        ; C=1: base += 8
    STA base
    BCS sur_end_sbc2_page           ; page cross → share handler
    BRA sur_end_sbc2_sec            ; → SEC, DEC, loop
sur_end_sbc2_row:
    DEC base+1
    DEC base+1                      ; base -= 512 (previous character row)
    LDY #7                          ; wrap sub-row to bottom
    BRA sur_end_sbc2_norow          ; C=1 preserved through DEC/LDY

    ; --- Fast-slow: second pixel Y-steps up ---
sur_end_fastslow:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    LDA color_both
    STA (base),Y
    DEY                             ; C=1 preserved
    BMI sur_end_fs_row
sur_end_fs_norow:
    ; Column advance via SBC (C=1 from ADC, preserved through DEY/BMI).
    LDA base
    SBC #$F8                        ; C=1: base += 8
    STA base
    BCS sur_end_fs_page             ; page cross (rare)
    BRA sur_end_sbc2_sec            ; → SEC, DEC, loop
sur_end_fs_page:
    INC base+1
    BRA sur_end_sbc2_sec
sur_end_fs_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA sur_end_fs_norow            ; C=1 preserved

    ; --- Slow: first pixel Y-steps up ---
sur_end_slow:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    DEY                             ; C=1 preserved
    BMI sur_end_slow_row
sur_end_slow_norow:
    ; C=1 here: from ADC (via DEY) or from CPY=8 match on row-cross path.
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    TXA                             ; C=1 preserved (TXA ≠ carry)
    BRA sur_end_sbc2
sur_end_slow_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA sur_end_slow_norow          ; C=1 preserved

; === sur: shallow, Y-up, X-right — exits in middle ====================

sur_mid_l:
    TAX
    DEC pixel_count
    BEQ sur_trail
    JSR sur_end_sbc1
sur_trail:
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    TXA
    SBC delta_minor                 ; C=1 from _end exit or dispatch
    BCS sur_trail_done
    ADC delta_major
    DEY
    BPL sur_trail_done
    DEC base+1
    DEC base+1
    LDY #7
sur_trail_done:
    RTS

sur_mid_r:
    JSR sur_end_r
    BRA sur_trail

; === sul: shallow, Y-up, X-left — exits at end ========================

sul_end_r:
    TAX
sul_end_loop:
    TXA                             ; A = error, C=1
sul_end_sbc1:
    SBC delta_minor
    BCC sul_end_slow
    SBC delta_minor
    BCC sul_end_fastslow

    ; --- Fast-fast: C=1, column retreat ---
    TAX
    LDA color_both
    STA (base),Y
    LDA base
    SBC #$08                        ; C=1: base -= 8
    STA base
    BCC sul_end_ff_borrow           ; page borrow (rare)
sul_end_ff_nopg:
    DEC pixel_count
    BNE sul_end_loop
    RTS
sul_end_ff_borrow:
    DEC base+1
    SEC
    BRA sul_end_ff_nopg

sul_end_l:
    TAX
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    TXA
    BRA sul_end_sbc2

    ; --- Second pixel, no Y-step (C=1) ---
sul_end_sbc2:
    SBC delta_minor
    BCC sul_end_sbc2_ystep
    TAX
    LDA base
    SBC #$08                        ; C=1: base -= 8
    STA base
    BCC sul_end_sbc2_borrow
sul_end_sbc2_nopg:
    DEC pixel_count
    BNE sul_end_loop
    RTS
sul_end_sbc2_borrow:
    DEC base+1
    SEC
    BRA sul_end_sbc2_nopg

    ; --- Second pixel, Y-step up (C=0 from SBC borrow) ---
sul_end_sbc2_ystep:
    ADC delta_major                 ; C=0 in; C=1 out (always)
    DEY                             ; C=1 preserved
    BMI sul_end_sbc2_row
sul_end_sbc2_norow:
    ; Column retreat via SBC (C=1 preserved through DEY/BMI).
    TAX
    LDA base
    SBC #$08                        ; C=1: base -= 8
    STA base
    BCS sul_end_sbc2_nopg           ; C=1 → no borrow (common)
    BRA sul_end_sbc2_borrow         ; C=0 → borrow (rare)
sul_end_sbc2_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA sul_end_sbc2_norow          ; C=1 preserved

    ; --- Fast-slow: second pixel Y-steps up ---
sul_end_fastslow:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    LDA color_both
    STA (base),Y
    DEY                             ; C=1 preserved
    BMI sul_end_fs_row
sul_end_fs_norow:
    ; Column retreat via SBC (C=1 from ADC, preserved through DEY/BMI).
    LDA base
    SBC #$08                        ; C=1: base -= 8
    STA base
    BCC sul_end_fs_borrow
sul_end_fs_nopg:
    DEC pixel_count
    BNE sul_end_loop
    RTS
sul_end_fs_borrow:
    DEC base+1
    SEC
    BRA sul_end_fs_nopg
sul_end_fs_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA sul_end_fs_norow            ; C=1 preserved

    ; --- Slow: first pixel Y-steps up ---
sul_end_slow:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    DEY                             ; C=1 preserved
    BMI sul_end_slow_row
sul_end_slow_norow:
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    TXA                             ; C=1 preserved
    BRA sul_end_sbc2
sul_end_slow_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA sul_end_slow_norow          ; C=1 preserved

; === sul: shallow, Y-up, X-left — exits in middle =====================

sul_mid_r:
    TAX
    DEC pixel_count
    BEQ sul_trail
    JSR sul_end_sbc1
sul_trail:
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    TXA
    SBC delta_minor                 ; C=1 from _end exit or dispatch
    BCS sul_trail_done
    ADC delta_major
    DEY
    BPL sul_trail_done
    DEC base+1
    DEC base+1
    LDY #7
sul_trail_done:
    RTS

sul_mid_l:
    JSR sul_end_l
    BRA sul_trail

; =====================================================================
; STEEP LOOPS
;
; Each pixel: read-modify-write with AND/ORA, one Y-step (major axis),
; conditional X-step (minor axis) on Bresenham borrow.
;
; X-step toggles pixel parity: tdr_l_xstep jumps to tdr_r_ystep and
; vice versa.  The column advance/retreat is encoded in the xstep
; handler, which chains C=1 from ADC delta_major into the address
; arithmetic (ADC #$07 = add 8 when C=1, ADC #$F7 = sub 8 when C=1).
;
; Y-down (tdr/tdl): uses INY/CPY #8 for row detection.  CPY leaves
; C=0 when Y<8 (common), requiring an explicit SEC before the next
; iteration.  Row-cross handlers skip the SEC since CPY #8 with Y=8
; leaves C=1.
;
; Y-up (tur/tul): uses DEY/BMI for row detection.  DEY does not
; affect carry, so C=1 from the SBC chain is naturally preserved —
; no SEC needed on the hot path.  X-step handlers inline the paired
; phase's ystep+loop to avoid a remote BRA.
; =====================================================================

; === tdr: steep, Y-down, X-right ======================================
; tdr_l draws left pixels, tdr_r draws right pixels.
; X-step toggles between the two phases.

tdr_l:
    TAX
tdr_l_px:
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    TXA
    SBC delta_minor                 ; C=1 (invariant)
    BCC tdr_l_xstep                 ; borrow → X-step + toggle to right
    TAX                             ; no borrow: C=1 preserved
tdr_l_ystep:
    INY
    CPY #8                          ; C=0 if Y<8 (common), C=1 if Y=8
    BEQ tdr_l_row                   ; row cross (rare, 1/8)
    SEC                             ; restore C=1 (CPY left C=0)
tdr_l_norow:
    DEC pixel_count
    BNE tdr_l_px
    RTS
tdr_l_row:
    INC base+1
    INC base+1
    LDY #0
    BRA tdr_l_norow                 ; C=1 from CPY #8 match

tdr_l_xstep:
    ADC delta_major                 ; C=0 in; C=1 out (always)
    TAX
    BRA tdr_r_ystep                 ; toggle to right-pixel phase

tdr_r:
    TAX
tdr_r_px:
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    TXA
    SBC delta_minor
    BCC tdr_r_xstep
    TAX
tdr_r_ystep:
    INY
    CPY #8
    BEQ tdr_r_row
    SEC
tdr_r_norow:
    DEC pixel_count
    BNE tdr_r_px
    RTS
tdr_r_row:
    INC base+1
    INC base+1
    LDY #0
    BRA tdr_r_norow                 ; C=1 from CPY

tdr_r_xstep:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    ; Column advance: base += 8.  ADC #$07 with C=1 = add 8.
    ; C=1 is chained from ADC delta_major, saving a CLC+ADC #$08.
    LDA base
    ADC #$07                        ; C=1 from ADC delta_major
    STA base
    BCC tdr_l_ystep                 ; no page cross → toggle to left phase
    INC base+1                      ; page cross (rare)
    BRA tdr_l_ystep

; === tdl: steep, Y-down, X-left =======================================

tdl_r:
    TAX
tdl_r_px:
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    TXA
    SBC delta_minor
    BCC tdl_r_xstep
    TAX
tdl_r_ystep:
    INY
    CPY #8
    BEQ tdl_r_row
    SEC
tdl_r_norow:
    DEC pixel_count
    BNE tdl_r_px
    RTS
tdl_r_row:
    INC base+1
    INC base+1
    LDY #0
    BRA tdl_r_norow                 ; C=1 from CPY

tdl_r_xstep:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    BRA tdl_l_ystep                 ; toggle to left-pixel phase

tdl_l:
    TAX
tdl_l_px:
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    TXA
    SBC delta_minor
    BCC tdl_l_xstep
    TAX
tdl_l_ystep:
    INY
    CPY #8
    BEQ tdl_l_row
    SEC
tdl_l_norow:
    DEC pixel_count
    BNE tdl_l_px
    RTS
tdl_l_row:
    INC base+1
    INC base+1
    LDY #0
    BRA tdl_l_norow                 ; C=1 from CPY

tdl_l_xstep:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    ; Column retreat: base -= 8.  ADC #$F7 with C=1 = add $F8 = sub 8.
    ; C=1 chained from ADC delta_major.
    LDA base
    ADC #$F7                        ; C=1 from ADC delta_major
    STA base
    BCS tdl_r_ystep                 ; C=1 → no borrow → toggle to right
    DEC base+1                      ; page borrow (rare)
    BRA tdl_r_ystep

; === tur: steep, Y-up, X-right ========================================
; Y-up eliminates SEC from the hot path: DEY/BMI preserves carry, so
; C=1 from SBC (no borrow) carries through to the next iteration.
; X-step handlers inline the cross-pixel ystep to avoid remote BRA.

tur_l:
    TAX
tur_l_px:
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    TXA
    SBC delta_minor                 ; C=1 (invariant)
    BCC tur_l_xstep                 ; borrow → X-step
    TAX                             ; C=1 from SBC no-borrow
    DEY                             ; C=1 preserved (DEY ≠ carry)
    BMI tur_l_row                   ; row cross (rare, 1/8)
tur_l_norow:
    DEC pixel_count                 ; C=1 preserved (DEC ≠ carry)
    BNE tur_l_px
    RTS
tur_l_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA tur_l_norow

tur_l_xstep:
    ADC delta_major                 ; C=0 in; C=1 out (always)
    TAX
    ; Inlined tur_r ystep — avoids BRA to remote tur_r_ystep.
    DEY                             ; C=1 preserved
    BMI tur_l_xs_row
tur_l_xs_norow:
    DEC pixel_count
    BNE tur_r_px                    ; → right-pixel phase
    RTS
tur_l_xs_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA tur_l_xs_norow

tur_r:
    TAX
tur_r_px:
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    TXA
    SBC delta_minor
    BCC tur_r_xstep
    TAX                             ; C=1 from SBC no-borrow
    DEY                             ; C=1 preserved
    BMI tur_r_row
tur_r_norow:
    DEC pixel_count                 ; C=1 preserved
    BNE tur_r_px
    RTS
tur_r_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA tur_r_norow

tur_r_xstep:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    ; Column advance: ADC #$07 with C=1 = add 8.
    LDA base
    ADC #$07                        ; C=1 from ADC delta_major
    STA base
    BCS tur_r_xs_page               ; page cross (rare, outlined)
tur_r_xs_sec:
    SEC                             ; C=0 after ADC no-overflow; restore for SBC
    ; Inlined tur_l ystep.
    DEY                             ; C=1 preserved
    BMI tur_r_xs_row
tur_r_xs_norow:
    DEC pixel_count
    BNE tur_l_px                    ; → left-pixel phase
    RTS
tur_r_xs_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA tur_r_xs_norow
tur_r_xs_page:
    INC base+1                      ; C=1 preserved (INC ≠ carry)
    BRA tur_r_xs_sec

; === tul: steep, Y-up, X-left =========================================
; Same Y-up carry-preservation pattern as tur.

tul_r:
    TAX
tul_r_px:
    LDA (base),Y
    AND #$EA
    ORA color_right
    STA (base),Y
    TXA
    SBC delta_minor
    BCC tul_r_xstep
    TAX                             ; C=1 from SBC no-borrow
    DEY                             ; C=1 preserved
    BMI tul_r_row
tul_r_norow:
    DEC pixel_count                 ; C=1 preserved
    BNE tul_r_px
    RTS
tul_r_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA tul_r_norow

tul_r_xstep:
    ADC delta_major                 ; C=0 in; C=1 out (always)
    TAX
    ; Inlined tul_l ystep.
    DEY                             ; C=1 preserved
    BMI tul_r_xs_row
tul_r_xs_norow:
    DEC pixel_count
    BNE tul_l_px                    ; → left-pixel phase
    RTS
tul_r_xs_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA tul_r_xs_norow

tul_l:
    TAX
tul_l_px:
    LDA (base),Y
    AND #$D5
    ORA color_left
    STA (base),Y
    TXA
    SBC delta_minor
    BCC tul_l_xstep
    TAX                             ; C=1 from SBC no-borrow
    DEY                             ; C=1 preserved
    BMI tul_l_row
tul_l_norow:
    DEC pixel_count                 ; C=1 preserved
    BNE tul_l_px
    RTS
tul_l_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA tul_l_norow

tul_l_xstep:
    ADC delta_major                 ; C=0 in; C=1 out
    TAX
    ; Column retreat: ADC #$F7 with C=1 = add $F8 = sub 8.
    LDA base
    ADC #$F7                        ; C=1 from ADC delta_major
    STA base
    BCC tul_l_xs_borrow             ; C=0 → page borrow (rare, outlined)
tul_l_xs_dey:
    ; Inlined tul_r ystep.  C=1 here (no borrow, or restored by SEC).
    DEY                             ; C=1 preserved
    BMI tul_l_xs_row
tul_l_xs_norow:
    DEC pixel_count
    BNE tul_r_px                    ; → right-pixel phase
    RTS
tul_l_xs_row:
    DEC base+1
    DEC base+1
    LDY #7
    BRA tul_l_xs_norow
tul_l_xs_borrow:
    DEC base+1
    SEC                             ; C=0 from borrow → restore for SBC
    BRA tul_l_xs_dey

; =====================================================================
; init_base — Compute screen address for pixel (x0, y0)
;
; Inputs:   x0           pixel X coordinate (0..127)
;           y0           pixel Y coordinate (0..159)
;           screen_page  high byte of screen buffer ($30 or $58)
;
; Outputs:  base         2-byte screen cell pointer
;           Y            sub-row within character cell (0..7)
;
; Clobbers: A, X
;
; Notes:    Must be called once before the first draw_line in a chain.
;
;   addr = screen_base + char_row*512 + byte_col*8 + sub_row
;   byte_col = x0 >> 1,  char_row = y0 >> 3,  sub_row = y0 & 7
;
;   The sub-row component is NOT folded into base; instead it lives
;   in Y and is added implicitly by (base),Y addressing in the loops.
;
;   High byte = screen_page + char_row*2 + (byte_col >= 32 ? 1 : 0)
;   Low byte  = (byte_col & 31) * 8
;
;   Implementation computes the low byte first: (x0 & $FE) << 2.
;   The second ASL naturally shifts x0 bit 6 (the byte_col >= 32 flag)
;   into the carry, which is then consumed by ADC screen_page to form
;   the high byte in a single branchless instruction.
; =====================================================================

init_base:
    ; char_row * 2 → X
    LDA y0
    AND #$F8                        ; char_row * 8 (clear sub-row bits)
    LSR A
    LSR A                           ; char_row * 2; C=0 (shifted-out bits
    TAX                             ;   were cleared by AND)

    ; Low byte: (x0 & $FE) << 2 = byte_col * 8 (mod 256)
    ; The second ASL shifts x0 bit 6 into carry:
    ;   C=1 iff byte_col >= 32 (x0 >= 64)
    LDA x0
    AND #$FE                        ; clear pixel-parity bit
    ASL A
    ASL A                           ; C = byte_col >= 32
    STA base

    ; High byte: char_row*2 + screen_page + carry, all in one ADC.
    ; C from ASL = byte_col overflow; X = char_row*2; C is preserved
    ; through STA/TXA (neither affects carry).
    TXA
    ADC screen_page                 ; char_row*2 + screen_page + C
    STA base+1                      ; no overflow possible: max $58+38+1=$7F

    ; Sub-row → Y (reloading y0 is cheaper than saving/restoring)
    LDA y0
    AND #$07
    TAY
    RTS
