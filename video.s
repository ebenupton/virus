; video.s — Double-buffered video management for BBC Micro MODE 2
;
; Provides: init_screen, clear_screen, clear_ship, wait_vsync, flip_buffers
; Requires: raster_zp.inc (for raster_page)
;
; ── Double-buffering scheme ─────────────────────────────────────────
; Two full MODE 2 frame buffers (128×160, layout described in raster.s):
;   buf0: $3000-$57FF        buf1: $5800-$7FFF
;
; The CRTC displays one buffer (R12/R13 = start address ÷ 8) while the
; rasterizer draws into the other (raster_page = $30 or $58, selected
; via set_page).  Per frame the main loop runs:
;   clear_screen → clear_ship → draw everything → wait_vsync → flip_buffers
;
; Because of double buffering, per-buffer state is two fields old when
; a buffer next becomes the back buffer — hence the paired _buf0/_buf1
; variables in video_zp.inc (dirty_top, ship_top, ship_bot), always
; indexed by back_buf_idx or derived from raster_page.
;
; Clears are dirty-region-limited: dirty_top_bufN records the topmost
; scan line the grid reached when that buffer was last drawn (160 =
; fully clean).  Everything above it is untouched black sky, except:
;   - char row 0: status bar, never cleared or redrawn here
;   - the minimap (rows 16-47): re-blitted by the main loop whenever
;     the dirty region overlapped it
;   - the ship, which can poke above the grid horizon: its stripes are
;     tracked separately and wiped by clear_ship

.include "video_zp.inc"

; ── Hardware registers ──────────────────────────────────────────────
; (also defined in game.s; safe to reference since these are constants)

; =====================================================================
; init_screen — CRTC setup, clear both buffers, init double-buffer state
; =====================================================================
; Inputs:   none (assumes MODE 2 video ULA setup done by the boot code)
; Outputs:  CRTC programmed, both buffers cleared, raster_page = $58,
;           back_buf_idx = 1 (draw into buf1, display buf0)
; Clobbers: A, X, Y
;
; CRTC registers written:
;   R1 (horizontal displayed) = 64 characters — 64 byte-columns = 128
;     MODE 2 pixels (the OS default MODE 2 is 80; this is a narrower,
;     square-ish playfield that makes a buffer exactly $2800 bytes)
;   R12/R13 (screen start, in units of 8 bytes) = $0600 → $3000 = buf0
;
; Pseudocode:
;   R1 = 64; R12:R13 = $3000 >> 3
;   dirty_top[0] = dirty_top[1] = 0     # fully dirty → clear all
;   for page in ($30, $58): set_page(page); clear_screen()
;   set_page($58); back_buf_idx = 1     # buf1 is the back buffer

init_screen:
    ; CRTC: 64 byte-columns (128 pixels at 4bpp), screen at $3000
    LDA #1
    STA CRTC_REG
    LDA #64
    STA CRTC_DAT

    LDA #12
    STA CRTC_REG
    LDA #$06
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #0
    STA CRTC_DAT

    ; Init dirty-top tracking (0 = fully dirty, clear everything)
    STA dirty_top_buf0
    STA dirty_top_buf1

    ; Clear both screen buffers
    LDA #$30
    JSR set_page
    JSR clear_screen
    LDA #$58
    JSR set_page
    JSR clear_screen

    ; Initialize double-buffer state: back buffer = buffer 1 ($5800)
    LDA #$58
    JSR set_page
    LDA #1
    STA back_buf_idx
    RTS

; =====================================================================
; wait_vsync — Wait for 2 vertical blanking interrupts
; =====================================================================
; Inputs:   none
; Outputs:  returns just after the second vsync pulse
; Clobbers: A, X
;
; Polls the System VIA interrupt flag register directly (no OS, no
; interrupt handler): IFR bit 1 = CA1, which is wired to the CRTC
; 50 Hz vertical sync.  Writing a 1 to an IFR bit acknowledges it,
; so `STA SYS_VIA_IFR` with A=$02 (the value left by the AND) clears
; the flag armed for the next field.
;
; Waiting for TWO pulses throttles the main loop to 25 fps and gives
; each displayed frame two full fields on screen; returning right at
; a sync pulse also means flip_buffers reprograms the CRTC during
; vertical blanking rather than mid-frame.
;
; Pseudocode:
;   for _ in range(2):
;       while not (SYS_VIA_IFR & 0x02): pass
;       SYS_VIA_IFR = 0x02              # acknowledge CA1 flag

wait_vsync:
    LDX #2
@vs_loop:
    LDA SYS_VIA_IFR
    AND #$02
    BEQ @vs_loop
    STA SYS_VIA_IFR           ; A=$02 from AND
    DEX
    BNE @vs_loop
    RTS

; =====================================================================
; flip_buffers — Swap display and back buffers via CRTC
; =====================================================================
; Inputs:   back_buf_idx = buffer just finished drawing (0 or 1)
; Outputs:  CRTC displays the just-drawn buffer; back_buf_idx and
;           raster_page (via set_page) select the other buffer
; Clobbers: A, X, Y
;
; CRTC R12/R13 hold the screen start address in units of 8 bytes:
;   show buf0 ($3000): R12=$06, R13=$00   ($3000 >> 3 = $0600)
;   show buf1 ($5800): R12=$0B, R13=$00   ($5800 >> 3 = $0B00)
; The new start address takes effect at the top of the next field.
;
; Pseudocode:
;   show = back_buf_idx                  # just-drawn buffer goes live
;   back_buf_idx = 1 - show
;   set_page($30 if show == 1 else $58)  # rasterizer → other buffer
;   R12:R13 = ($5800 if show == 1 else $3000) >> 3

flip_buffers:
    LDA back_buf_idx
    BEQ @show_buf0
    ; Will show buffer 1: R12=$0B, back→buf0
    LDX #$0B
    LDA #$30
    LDY #0
    BEQ @do_flip              ; always taken (Y=0)
@show_buf0:
    ; Will show buffer 0: R12=$06, back→buf1
    LDX #$06
    LDA #$58
    LDY #1
@do_flip:
    STY back_buf_idx
    JSR set_page
    LDA #12
    STA CRTC_REG
    STX CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #0
    STA CRTC_DAT
    RTS

; =====================================================================
; clear_screen — Clear back buffer with dirty-top SMC optimisation
; =====================================================================
; Patches the BNE operand to skip clean stripes on iterations 1..255.
; First iteration (X=0) always falls through all STZs.
;
; Inputs:   raster_page ($30/$58) selects the buffer to clear
;           dirty_top_bufN = topmost dirty scan line (0..160) recorded
;             when this buffer was last drawn (160 = fully clean)
; Outputs:  buffer zeroed from the dirty char row down to the bottom
; Clobbers: A, X, Y
;
; PAGE-PARALLEL CLEAR
;   Each buffer has a fully unrolled loop of 38 STA $pp00,X — one per
;   256-byte page of the buffer, char row 0 excluded (status bar).
;   X is the byte offset WITHIN a page: each of the 256 iterations
;   writes byte X of every (dirty) page, so the clear sweeps all pages
;   "in parallel" with a single INX/BNE of loop overhead per 38 writes.
;
; SMC HEIGHT LIMIT
;   A char row (512-byte stripe) is two consecutive pages, so the
;   dirty top converts to a page index:
;     p = (dirty_top >> 2) & $FE  =  2 * char_row(dirty_top),  0..40
;   and N = max(0, p-2) pages of the loop lie wholly above the dirty
;   row (the -2 accounts for char row 0 already being omitted).
;   The loop body is 38 STA abs,X (114 bytes) + INX (1) = 115 bytes,
;   so BNE operand -117 ($8B) re-enters at the first STA and each +3
;   skips one more STA.  Patching the operand to N*3 - 117 (via the
;   LUT below) makes iterations 1..255 touch only the dirty pages.
;   Iteration 0 (entry falls through the whole list) still writes
;   byte 0 of every page — harmless: clean pages are already zero.
;
; Pseudocode:
;   buf = 1 if raster_page == $58 else 0
;   N = max(0, 2 * (dirty_top[buf] >> 3) - 2)   # clean pages to skip
;   clrN_bne.operand = N*3 - 117                # SMC patch
;   for X in range(256):                        # A = 0 throughout
;       for page in loop_pages[0 if X == 0 else N:]:
;           page[X] = 0

; BNE offset LUT indexed by page_index (0..40)
; page_index p: N = max(0, p-2) pages to skip
; BNE operand = N*3 - 117  (signed, relative to BNE+2)
bne_offset_lut:
    .byte $8B,$8B,$8B,$8E,$91,$94,$97,$9A,$9D,$A0,$A3,$A6,$A9,$AC,$AF,$B2,$B5,$B8,$BB,$BE
    .byte $C1,$C4,$C7,$CA,$CD,$D0,$D3,$D6,$D9,$DC,$DF,$E2,$E5,$E8,$EB,$EE,$F1,$F4,$F7,$FA,$FD

clear_screen:
    LDX #0
    LDA raster_page
    CMP #$58
    BNE clr_got_buf
    INX                       ; X=1 for buf1
clr_got_buf:
    LDA dirty_top_buf0,X     ; dirty_top for this buffer
    LSR A
    LSR A                     ; page_index (0..40)
    AND #$FE                  ; round to char row (left+right page pair)
    TAY
    LDA bne_offset_lut,Y     ; BNE operand
    DEX
    BPL clr_do_buf1
    STA clr0_bne + 1         ; SMC: patch buf0 BNE

clear_buf0:
    LDX #0
    TXA
clr0_loop:
    ; Skip char row 0 ($3000-$31FF) — preserved for status bar
    STA $3200,X
    STA $3300,X
    STA $3400,X
    STA $3500,X
    STA $3600,X
    STA $3700,X
    STA $3800,X
    STA $3900,X
    STA $3A00,X
    STA $3B00,X
    STA $3C00,X
    STA $3D00,X
    STA $3E00,X
    STA $3F00,X
    STA $4000,X
    STA $4100,X
    STA $4200,X
    STA $4300,X
    STA $4400,X
    STA $4500,X
    STA $4600,X
    STA $4700,X
    STA $4800,X
    STA $4900,X
    STA $4A00,X
    STA $4B00,X
    STA $4C00,X
    STA $4D00,X
    STA $4E00,X
    STA $4F00,X
    STA $5000,X
    STA $5100,X
    STA $5200,X
    STA $5300,X
    STA $5400,X
    STA $5500,X
    STA $5600,X
    STA $5700,X
    INX
clr0_bne:
    BNE clr0_loop
    RTS

clr_do_buf1:
    STA clr1_bne + 1         ; SMC: patch buf1 BNE

clear_buf1:
    TXA                       ; X=0 from clr_do_buf1 path
clr1_loop:
    ; Skip char row 0 ($5800-$59FF) — preserved for status bar
    STA $5A00,X
    STA $5B00,X
    STA $5C00,X
    STA $5D00,X
    STA $5E00,X
    STA $5F00,X
    STA $6000,X
    STA $6100,X
    STA $6200,X
    STA $6300,X
    STA $6400,X
    STA $6500,X
    STA $6600,X
    STA $6700,X
    STA $6800,X
    STA $6900,X
    STA $6A00,X
    STA $6B00,X
    STA $6C00,X
    STA $6D00,X
    STA $6E00,X
    STA $6F00,X
    STA $7000,X
    STA $7100,X
    STA $7200,X
    STA $7300,X
    STA $7400,X
    STA $7500,X
    STA $7600,X
    STA $7700,X
    STA $7800,X
    STA $7900,X
    STA $7A00,X
    STA $7B00,X
    STA $7C00,X
    STA $7D00,X
    STA $7E00,X
    STA $7F00,X
    INX
clr1_bne:
    BNE clr1_loop
    RTS

; =====================================================================
; clear_ship — Clear ship stripes above grid dirty line
; =====================================================================
; Zeros a 20-pixel-wide strip at screen centre for ship stripes that
; are above the grid dirty line (not cleared by clear_screen).
;
; Inputs:   back_buf_idx, raster_page = back buffer
;           ship_top/ship_bot_bufN = char-row span (0..19) the ship
;             occupied when this buffer was last drawn (20 = no ship)
;           dirty_top_bufN = grid dirty top for the same frame
; Outputs:  ship stripes wiped; ship_top/bot_bufN reset to 20 (none)
; Clobbers: A, X, Y, cs_* workspace (ZP_SHARED)
;
; The ship is drawn at screen centre and can extend above the grid
; horizon, i.e. above the region clear_screen wipes.  For each char-row
; stripe the ship touched, this zeros a 10-byte-column (20-pixel) strip
; covering byte columns 27..36 (pixels X = 54..73, centred on 64).
; Within a stripe that strip is two 40-byte runs:
;   first page,  offsets $D8..$FF — columns 27..31
;   second page, offsets $00..$27 — columns 32..36
; Stripes at or below the grid dirty char row (cs_cur >= cs_grid) were
; already zeroed by clear_screen this frame and are skipped.
;
; Pseudocode:
;   top, bot = ship_top[back], ship_bot[back]
;   if top >= 20: return                    # no ship last frame
;   ship_top[back] = ship_bot[back] = 20
;   for row in range(top, bot + 1):         # char-row stripes
;       if row < dirty_top[back] >> 3:      # above grid horizon only
;           memset(row_base(row) + $D8, 0, 40)    # cols 27..31
;           memset(row_base(row) + $100, 0, 40)   # cols 32..36

cs_ptr   = ZP_SHARED + 1
cs_cur   = ZP_SHARED + 3
cs_grid  = ZP_SHARED + 4
cs_bot   = ZP_SHARED + 5

clear_ship:
    LDX back_buf_idx
    LDA ship_top_buf0,X
    CMP #20
    BCS @cs_done              ; no ship drawn last frame

    STA cs_cur                ; current stripe = ship top
    LDA dirty_top_buf0,X
    LSR A
    LSR A
    LSR A                     ; scan line → char row (÷8)
    STA cs_grid
    LDA ship_bot_buf0,X
    STA cs_bot
    LDA #20                   ; mark ship gone for this buffer
    STA ship_top_buf0,X
    STA ship_bot_buf0,X

@cs_loop:
    LDA cs_cur
    CMP cs_grid
    BCS @cs_skip              ; >= grid dirty → already cleared

    ; cs_ptr = stripe base + $D8: hi = raster_page + 2*row, lo = $D8
    ASL A
    CLC
    ADC raster_page
    STA cs_ptr+1
    LDA #$D8
    STA cs_ptr

    ; First 40-byte run: offsets $D8..$FF = byte columns 27..31
    LDA #0
    LDY #39
:   STA (cs_ptr),Y
    DEY
    BPL :-

    ; Second 40-byte run: next page, offsets $00..$27 = columns 32..36
    INC cs_ptr+1
    LDY #0
    STY cs_ptr
    LDY #39
:   STA (cs_ptr),Y
    DEY
    BPL :-

@cs_skip:
    INC cs_cur
    LDA cs_cur
    CMP cs_bot
    BCC @cs_loop              ; loop while cs_cur <= cs_bot
    BEQ @cs_loop              ;   (bottom stripe inclusive)
@cs_done:
    RTS

