; demo.s — BBC Micro Line Rasterizer Demo
; Assembled with ca65: ca65 --cpu 65C02 demo.s -o demo.o
; Linked with ld65:    ld65 -C linker.cfg demo.o -o demo.bin
;
; Loads and runs at $3000.
; Switches to a 256x256 1bpp display by reprogramming the 6845 CRTC
; from MODE 4 (320x256) to 32 displayed characters = 256 pixels wide.
; Screen memory is relocated to $4000-$5FFF (1-page character row stride).
; Continuously draws random Bresenham lines via a 16-bit Galois LFSR.

.setcpu "65C02"
.segment "CODE"

; --- MOS entry points ---
OSWRCH      = $FFEE
OSBYTE      = $FFF4

; --- Hardware registers ---
CRTC_REG    = $FE00
CRTC_DAT    = $FE01

; --- Zero page ---
base        = $70           ; 2 bytes: screen pointer
delta_minor = $72           ; 1 byte
delta_major = $73           ; 1 byte
mask_zp     = $74           ; 1 byte: current pixel bitmask
cols_left   = $75           ; shallow: negated column counter
stripes_left = $75          ; steep: negated stripe counter (alias)
final_branch = $76          ; shallow: precomputed BBR/BCC opcode
final_bias  = $76           ; steep: y_end & 7 (alias)
x0          = $80
y0          = $81
x1          = $82
y1          = $83
screen_page = $84
lfsr_lo     = $90
lfsr_hi     = $91

; --- Opcodes for self-modifying code ---
opLSRzp     = $46
opASLzp     = $06
opBCC       = $90
opNOP       = $EA
opBBR0      = $0F
opBBR1      = $1F
opBBR2      = $2F
opBBR3      = $3F
opBBR4      = $4F
opBBR5      = $5F
opBBR6      = $6F
opBBR7      = $7F

; =============================================================================
; Entry point ($3000)
; =============================================================================
;
; MODE 4 is selected via the OS (which sets ULA, palette and CRTC
; defaults), then four raw CRTC writes narrow the display to 32
; characters (256 px) and move the screen base to $4000.  At 32 bytes
; per scanline a character row is exactly 256 bytes, so stepping
; between char rows is a single INC/DEC of the pointer high byte.
;
; Pseudocode:
;   mode(4); cursor_off(); wait_vsync()
;   crtc[1]=32; crtc[2]=45; crtc[10]=$20; crtc[12:13]=$0800  # base $4000
;   memset($4000, 0, $4000)
;   seed LFSR with $ACE1
;   while True:
;       x0,y0 = rand(), lfsr_hi; x1,y1 = rand(), lfsr_hi
;       draw_line()

entry:
    ; Switch to MODE 4 (320x256, 1bpp — sets up ULA, palette, CRTC defaults)
    LDA #22
    JSR OSWRCH
    LDA #4
    JSR OSWRCH

    ; Disable text cursor (VDU 23,1,0,0,0,0,0,0,0,0)
    LDA #23
    JSR OSWRCH
    LDA #1
    JSR OSWRCH
    LDA #0
    LDX #8
@vdu_zero:
    JSR OSWRCH
    DEX
    BNE @vdu_zero

    ; Wait for VSync before reprogramming CRTC
    LDA #19
    JSR OSBYTE

    ; --- Reprogram 6845 CRTC ---
    ; R1 = 32 (display 32 characters = 256 pixels wide)
    LDA #1
    STA CRTC_REG
    LDA #32
    STA CRTC_DAT

    ; R2 = 45 (center 32-char display within 64-char line; default 49 for 40-char)
    LDA #2
    STA CRTC_REG
    LDA #45
    STA CRTC_DAT

    ; R10 = $20 (hardware cursor off)
    LDA #10
    STA CRTC_REG
    LDA #$20
    STA CRTC_DAT

    ; R12:R13 = $0800 (screen start address → physical $4000)
    ; MA range $0800-$0FFF keeps MA12=0, avoiding screenSubtract adjustment.
    LDA #12
    STA CRTC_REG
    LDA #$08
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #$00
    STA CRTC_DAT

    ; --- Clear screen ($4000-$7FFF = 16 KB) ---
    LDA #0
    TAY
    LDX #$40
    STX base+1
    STY base
@clear_page:
    STA (base),Y
    INY
    BNE @clear_page
    INC base+1
    LDX base+1
    CPX #$80
    BNE @clear_page

    ; --- Initialise ---
    LDA #$40
    STA screen_page
    LDA #$E1            ; LFSR seed = $ACE1 (any non-zero value)
    STA lfsr_lo
    LDA #$AC
    STA lfsr_hi

    ; --- Main loop: draw random lines forever ---
main_loop:
    JSR lfsr_next
    STA x0
    LDA lfsr_hi
    STA y0
    JSR lfsr_next
    STA x1
    LDA lfsr_hi
    STA y1
    JSR draw_line
    JMP main_loop

; =============================================================================
; 16-bit Galois LFSR pseudorandom number generator
; Polynomial: x^16 + x^14 + x^13 + x^11 + 1   (period 65535)
; XOR mask $B400 on high byte when carry out
; Returns: random byte in A (low byte of LFSR state)
; =============================================================================
; Right-shifting Galois form; state in lfsr_hi:lfsr_lo, must be non-zero.
; Preserves: X, Y
;
; Pseudocode:
;   out = state & 1; state >>= 1
;   if out: state ^= $B400
;   return state & 0xFF

lfsr_next:
    LSR lfsr_hi
    ROR lfsr_lo
    BCC @no_eor
    LDA lfsr_hi
    EOR #$B4
    STA lfsr_hi
@no_eor:
    LDA lfsr_lo
    RTS

; =============================================================================
; Lookup tables
; =============================================================================

; Pixel bitmask for bit position (x & 7), MSB-first
mask_init_table:
    .byte $80, $40, $20, $10, $08, $04, $02, $01

; BBR opcode tables indexed by x1 & 7 (shallow path only).
; fwd_branch_table[7] intentionally reads into rev_branch_table[0] = $90 (BCC),
; acting as a sentinel that keeps the default BCC loop branch.
fwd_branch_table:
    .byte opBBR6, opBBR5, opBBR4, opBBR3, opBBR2, opBBR1, opBBR0
rev_branch_table:
    .byte opBCC, opBBR7, opBBR6, opBBR5, opBBR4, opBBR3, opBBR2, opBBR1

; =============================================================================
; draw_line — Combined Bresenham line rasterizer for 65C02
;
; Inputs: x0, y0, x1, y1  (0-255 each)
;         screen_page      (high byte of screen base, e.g. $40)
; Output: line XOR-drawn from (x0,y0) to (x1,y1) inclusive
; Clobbers: A, X, Y, base, mask_zp, delta_minor/major, cols/stripes_left,
;           final_branch/bias; x0/y0 are overwritten in the reverse cases
;
; Screen bytes hold 8 pixels MSB-first; a character cell is 8 bytes
; (8 scanlines) and a char row of 32 cells is one 256-byte page, so
; addressing is base = page(y>>3) + (x & $F8), scanline index in Y.
;
; Pseudocode (integer Bresenham, error term d kept in X):
;   if x1 < x0: swap endpoints          # dx >= 0 from here on
;   dy = abs(y0 - y1); dx = x1 - x0
;   if dx >= dy: shallow path           # step x every pixel, y sometimes
;   else:        steep path             # step y every pixel, x sometimes
; =============================================================================

draw_line:
    ; Ensure x1 >= x0 (swap endpoints if needed)
    LDA x1
    CMP x0
    BCS @no_swap
    LDX x0
    STA x0
    STX x1
    LDA y0
    LDX y1
    STA y1
    STX y0
@no_swap:
    ; Compute |dy| = |y0 - y1|
    LDA y0
    SEC
    SBC y1
    BCS @abs_dy
    EOR #$FF
    INC A
@abs_dy:
    TAY                     ; Y = |dy|
    ; Compute dx = x1 - x0
    LDA x1
    SEC
    SBC x0                  ; A = dx
    ; Dispatch: dx >= |dy| → shallow, else steep
    STY delta_minor         ; temp stash |dy|
    CMP delta_minor
    BCS shallow_setup
    JMP steep_setup

; =============================================================================
; SHALLOW PATH — major axis X, minor axis Y
; =============================================================================
;
; One pixel per iteration along X: XOR mask_zp into (base),Y, then walk
; the mask across the byte; the shift's carry-out (C=1) flags an
; 8-pixel column boundary.  Y only ever steps upward (DEY, DEC base+1
; across char rows) — when y1 > y0 the endpoints are swapped and the
; line is drawn from the other end with x running right-to-left.
;
; The x direction is compiled into the loop via self-modifying code:
;   smc_s_shift    LSR (fwd) / ASL (rev)  — mask walk direction
;   smc_s_mask     #$80 / #$01            — mask reload after column step
;   smc_s_advance  +8  / -8               — byte column advance (+C)
;
; Termination is also SMC: normal columns loop on BCC (no shift-out);
; on entering the final column the 3-byte branch is rewritten to
; BBR(n) mask_zp — n chosen from x1&7 so the branch falls through
; right after the last pixel's shift lands on bit n.  End position 7
; keeps the BCC (table sentinel $90): the shift-out itself ends the
; column, and the negated cols_left counter (INC → 0 means "final
; column next", >0 means done) supplies the exit.
;
; Loop invariant: C=0 on entry, error term d in X, delta_minor holds
; dy-1 so `SBC delta_minor` with C=0 computes d - dy in one op.
;
; Pseudocode (forward case):
;   d = dx - dy
;   for each x from x0 to x1:
;       screen[base + Y] ^= mask
;       d -= dy
;       if d < 0: d += dx; Y -= 1        # minor-axis step (up)
;       mask >>= 1                       # next pixel; C=1 on column end
;
shallow_setup:
    ; Entry: A = dx, Y = |dy|, delta_minor = |dy|, C=1 from CMP
    STA delta_major

    ; cols_left = -((x1>>3) - (x0>>3))
    LDA x1
    ORA #$07
    SBC x0                  ; C=1: exact (x1|7) - x0
    LSR
    LSR
    LSR
    EOR #$FF
    INC A
    STA cols_left

    ; Branch on y-direction
    LDA y0
    CMP y1
    BCC @s_setup_reverse

    ; === FORWARD (y0 >= y1): draw left-to-right, bottom-to-top ===
    LDA x1
    AND #$07
    TAX
    LDA fwd_branch_table,X
    STA final_branch

    LDA #opLSRzp
    LDX #$80
    LDY #$07
    BRA @s_setup_common

    ; === REVERSE (y1 > y0): swap and draw right-to-left, bottom-to-top ===
@s_setup_reverse:
    LDA x0
    AND #$07
    TAX
    LDA rev_branch_table,X
    STA final_branch

    LDA x1
    STA x0
    LDA y1
    STA y0

    LDA #opASLzp
    LDX #$01
    LDY #$F7

@s_setup_common:
    STA smc_s_shift
    STX smc_s_mask + 1
    STY smc_s_advance + 1

    JSR init_base

    ; Write default BCC branch (fast path for normal columns)
    LDA #opBCC
    STA smc_s_branch
    LDA #<(s_pixel_loop - (smc_s_branch + 2))
    STA smc_s_branch + 1
    LDA #opNOP
    STA smc_s_branch + 2

    ; Single-column case: write final branch for immediate termination
    LDA cols_left
    BNE @s_setup_multi
    JSR s_write_final_branch

@s_setup_multi:
    ; d = dx - dy
    LDA delta_major
    SEC
    SBC delta_minor
    TAX

    ; Adjust delta_minor: store dy-1 for the C=0 SBC trick
    LDA delta_minor
    BEQ @s_keep
    DEC delta_minor
@s_keep:
    CLC                     ; C=0 for pixel_loop entry

; -----------------------------------------------
; Shallow inner loop (rerolled)
; Invariant: C=0 on entry, d in X
; -----------------------------------------------
s_pixel_loop:
    LDA (base),Y
    EOR mask_zp
    STA (base),Y
    TXA
    SBC delta_minor         ; C=0: A - (dy-1) - 1 = A - dy
    BCS @s_no_ystep
    ADC delta_major         ; d += dx
    DEY
    BPL @s_no_ystep
    DEC base+1              ; cross character row boundary
    LDY #7
@s_no_ystep:
    TAX
smc_s_shift:
    LSR mask_zp             ; SMC: LSR (fwd) / ASL (rev)
smc_s_branch:
    BCC s_pixel_loop        ; SMC: BCC+NOP (normal) / BBR(N) (final col)
    NOP

    ; --- Column transition (C=1 from last-bit shift-out) ---
    LDA base
smc_s_advance:
    ADC #7                  ; SMC: +7+C=+8 (fwd) / +$F7+C=-8 (rev)
    STA base
smc_s_mask:
    LDA #$80                ; SMC: $80 (fwd) / $01 (rev)
    STA mask_zp

    INC cols_left
    BMI @s_resume
    BNE @s_complete
    JSR s_write_final_branch
@s_resume:
    CLC
    BRA s_pixel_loop
@s_complete:
    RTS

; -----------------------------------------------
; Write precomputed branch to smc_s_branch
; If final_branch = $90 (BCC), leaves BCC default.
; Preserves: C, X, Y
; -----------------------------------------------
s_write_final_branch:
    LDA final_branch
    BMI @s_wfb_done         ; bit 7 set → $90 (BCC sentinel)
    STA smc_s_branch        ; byte 0: BBR opcode
    LDA #mask_zp
    STA smc_s_branch + 1    ; byte 1: ZP address ($74)
    LDA #<(s_pixel_loop - (smc_s_branch + 3))
    STA smc_s_branch + 2    ; byte 2: backward offset
@s_wfb_done:
    RTS

; =============================================================================
; STEEP PATH — major axis Y, minor axis X
; =============================================================================
;
; One pixel per iteration along Y, walked in 8-scanline stripes (one
; char row each): Y counts the scanline 7..0 within the stripe, and a
; stripe transition is DEC base+1.  As in the shallow path, Y always
; steps upward and reverse lines (y1 > y0) are drawn from the other
; endpoint; the occasional x step shifts mask_zp, with the same SMC
; trio (smc_t_shift / smc_t_mask / smc_t_col_advance) selecting
; direction.
;
; The stripe counter is negated: INC → negative means more full
; stripes, zero means the final (possibly partial) stripe is next.
; final_bias = y_end & 7 trims that last stripe — base is advanced by
; the bias and Y starts at 7-bias so the loop stops exactly on y_end.
; (In the single-stripe case the same adjustment is applied at setup.)
;
; Loop invariant: C=1 on entry (re-established after every step), so
; `SBC delta_minor` computes d - dx directly; d lives in X.
;
; Pseudocode (forward case):
;   d = dy - dx
;   for each y from y0 down to y1:
;       screen[base + Y] ^= mask
;       d -= dx
;       if d < 0:
;           d += dy
;           mask >>= 1                   # minor-axis step (x)
;           if mask shifted out: base += 8; mask = $80   # next column
;       Y -= 1                           # next scanline up
;
steep_setup:
    ; Entry: A = dx, Y = |dy|, delta_minor = |dy| (will be overwritten)
    STA delta_minor         ; delta_minor = dx
    STY delta_major         ; delta_major = |dy|

    LDA y0
    CMP y1
    BCC @t_setup_reverse

    ; === FORWARD (y0 >= y1) ===
    LDA y1
    AND #$07
    STA final_bias

    LDA y0
    ORA #$07
    SBC y1                  ; C=1 from CMP
    LSR
    LSR
    LSR
    EOR #$FF
    INC A
    STA stripes_left

    LDA #opLSRzp
    LDX #$80
    LDY #$07
    BRA @t_setup_common

    ; === REVERSE (y1 > y0) ===
@t_setup_reverse:
    LDA y0
    AND #$07
    STA final_bias

    LDA y1
    ORA #$07
    SEC
    SBC y0
    LSR
    LSR
    LSR
    EOR #$FF
    INC A
    STA stripes_left

    LDA x1
    STA x0
    LDA y1
    STA y0

    LDA #opASLzp
    LDX #$01
    LDY #$F7

@t_setup_common:
    STA smc_t_shift
    STX smc_t_mask + 1
    STY smc_t_col_advance + 1

    JSR init_base

    ; Single-stripe case: adjust base for final_bias
    LDA stripes_left
    BNE @t_setup_multi
    LDA base
    CLC
    ADC final_bias
    STA base
    TYA
    SEC
    SBC final_bias
    TAY

@t_setup_multi:
    ; d = dy - dx
    LDA delta_major
    SEC
    SBC delta_minor
    TAX
    ; C=1 guaranteed (dy > dx on steep path)

; -----------------------------------------------
; Steep inner loop (rolled)
; Invariant: C=1 on entry, d in X
; -----------------------------------------------
t_pixel_loop:
    LDA (base),Y
    EOR mask_zp
    STA (base),Y
    TXA
    SBC delta_minor         ; C=1: d - dx
    BCS t_no_xstep
    ADC delta_major         ; d += dy, C=1 guaranteed
smc_t_shift:
    LSR mask_zp             ; SMC: LSR (fwd) / ASL (rev)
    BCC t_xdone
    ; Column crossing (C=1 from shift-out)
    PHA
    LDA base
smc_t_col_advance:
    ADC #$07                ; SMC: +7+C=+8 (fwd) / +$F7+C=-8 (rev)
    STA base
smc_t_mask:
    LDA #$80                ; SMC: $80 (fwd) / $01 (rev)
    STA mask_zp
    PLA
t_xdone:
    SEC
t_no_xstep:
    TAX
    DEY
    BPL t_pixel_loop

    ; --- Stripe transition ---
    INC stripes_left
    BMI @t_normal_stripe
    BNE @t_complete

    ; Entering final stripe
    DEC base+1              ; cross character row boundary
    LDA base
    CLC
    ADC final_bias
    STA base
    LDA #7
    SEC
    SBC final_bias
    TAY
    SEC
    BRA t_pixel_loop

@t_normal_stripe:
    DEC base+1              ; cross character row boundary
    LDY #7
    SEC
    BRA t_pixel_loop

@t_complete:
    RTS

; =============================================================================
; init_base — compute base pointer and mask from x0, y0
; Clobbers: A, X, Y
; =============================================================================
; Input:  x0, y0 (pixel coords), screen_page
; Output: base    = (screen_page + y0/8) * 256 + (x0 & $F8)  # char cell
;         Y       = y0 & 7          # scanline in cell; (base),Y = pixel byte
;         mask_zp = $80 >> (x0 & 7) # MSB-first pixel bit
; =============================================================================

init_base:
    LDA x0
    AND #$07
    TAX
    LDA mask_init_table,X
    STA mask_zp

    LDA y0
    LSR
    LSR
    LSR                     ; y0 / 8 = character row
    CLC
    ADC screen_page
    STA base+1

    LDA x0
    AND #$F8
    STA base

    LDA y0
    AND #$07
    TAY
    RTS
