; raster.s — Shallow line rasterizer (dx >= dy) for 65C02
; Gated on byte columns (X axis), mirroring steep rasterizer's clean termination.
;
; Rerolled inner loop: single pixel body with LSR/ASL shift before branch.
; LSR for forward / ASL for reverse (SMC).  Shift occurs after pixel plot.
;
; .smc_branch is a 3-byte SMC slot.
; Normal columns: BCC pixel_loop + NOP (32 cycles/pixel).
;   C=0 from LSR/ASL loops back; C=1 when last bit shifts out falls through.
; Final column: BBR(N) mask_zp, pixel_loop (34 cycles/pixel).
;   BBR detects the termination bit and falls through
;   Full-column endpoints (x1&7=7 fwd, x1&7=0 rev) keep BCC mode
;   since the column empties to $00 via carry, which BBR can't catch.
;   Overlapping tables (fwd/rev) indexed by x1&7 give BBR opcode or $90 (BCC).
; Outer loop counts byte columns via INC toward zero.
;
; Carry invariant: C=0 at pixel_loop entry (from LSR/ASL or column CLC).
; Column transitions reload mask_zp via SMC immediate and CLC.
; Storing dy-1 in delta_minor makes SBC with C=0 subtract dy.

; Zero page variables
base            = $70       ; 2 bytes - pointer to current position
delta_minor     = $72       ; 1 byte - dy-1 (or 0 when dy=0)
delta_major     = $73       ; 1 byte - dx (added back on y-step)
mask_zp         = $74       ; 1 byte - current pixel bitmask
cols_left       = $75       ; 1 byte - negated column counter (INC toward 0)
final_branch    = $76       ; 1 byte - precomputed BBR/BCC opcode
x0              = $80
y0              = $81
x1              = $82
y1              = $83
screen_page     = $84

; Opcodes used in self-modifying code
opLSRzp         = $46
opASLzp         = $06
opBCC           = $90
opNOP           = $EA
opBBR0          = $0F
opBBR1          = $1F
opBBR2          = $2F
opBBR3          = $3F
opBBR4          = $4F
opBBR5          = $5F
opBBR6          = $6F
opBBR7          = $7F

; Mask initialization lookup table
mask_init_table:
    .byte $80, $40, $20, $10, $08, $04, $02, $01

; BBR opcode tables indexed by x1 & 7.
; $90 (BCC) sentinel shared: fwd_branch_table[7] = rev_branch_table[0].
fwd_branch_table:
    .byte opBBR6, opBBR5, opBBR4, opBBR3, opBBR2, opBBR1, opBBR0
rev_branch_table:
    .byte  opBCC, opBBR7, opBBR6, opBBR5, opBBR4, opBBR3, opBBR2, opBBR1

;---------------------------------------
; Main drawing routine
; Inputs: x0, y0, x1, y1, screen_page
; Requires: dx >= dy, x1 >= x0
;---------------------------------------

draw_line:
    ; === Common preamble ===

    LDX x1

    ; delta_major = dx = x1 - x0
    TXA
    SEC
    SBC x0
    STA delta_major

    ; cols_left = (x0>>3) - (x1>>3) [always <= 0]
    ; C=1 from delta_major SBC (x1 >= x0)
    ; (x1|7) - x0 = (x1>>3 - x0>>3)*8 + (7 - (x0&7)), remainder in [0,7]
    TXA
    ORA #$07
    SBC x0                  ; C=1: exact (x1|7) - x0
    LSR
    LSR
    LSR                     ; A = (x1>>3) - (x0>>3)
    EOR #$FF
    INC A                   ; negate
    STA cols_left

    ; Compute dy = y0 - y1, branch on direction
    LDA y0
    SEC
    SBC y1
    BCC .setup_reverse      ; y1 > y0: reverse

    ;===================================
    ; SETUP FORWARD (y0 >= y1, left-to-right)
    ;===================================
.setup_forward:
    ; Forward: A = y0 - y1 = |dy|
    STA delta_minor

    ; Precompute branch opcode for final column
    TXA
    AND #$07
    TAY
    LDA fwd_branch_table,Y
    STA final_branch

    LDA #opLSRzp
    LDX #$80
    LDY #$07

    BRA .setup_common

    ;===================================
    ; SETUP REVERSE (y1 > y0, right-to-left after swap)
    ;===================================
.setup_reverse:
    ; Reverse: A = y0 - y1 (negative), negate for |dy|
    EOR #$FF
    INC A
    STA delta_minor

    ; Precompute branch opcode for final column
    LDA x0
    AND #$07
    TAY
    LDA rev_branch_table,Y
    STA final_branch

    ; x0 <-- x1 (x1 not read after this point)
    STX x0

    ; y0 <-- y1 (y1 not read after this point)
    LDA y1
    STA y0

    LDA #opASLzp
    LDX #$01
    LDY #$F7

    ; Fall through to .setup_common

    ;===================================
    ; SETUP COMMON (always upward after possible swap)
    ;===================================
.setup_common:
    STA .smc_shift
    STX .smc_mask + 1
    STY .smc_advance + 1

    ; mask_zp = mask_init_table[x0 & 7]
    LDA x0
    AND #$07
    TAX
    LDA mask_init_table,X
    STA mask_zp

    ; base+1 = (y0/8) + screen_page
    LDA y0
    LSR
    LSR
    LSR
    CLC
    ADC screen_page
    STA base+1

    ; base = x0 & $F8
    LDA x0
    AND #$F8
    STA base

    ; Y = y0 & 7
    LDA y0
    AND #$07
    TAY

    ; Write BCC default to .smc_branch (fast path for normal columns)
    LDA #opBCC
    STA .smc_branch
    LDA #<(pixel_loop - (.smc_branch + 2))   ; backward offset to pixel_loop
    STA .smc_branch + 1
    LDA #opNOP                            ; NOP padding
    STA .smc_branch + 2

    ; Single-column override: write branch for immediate termination
    LDA cols_left
    BNE .setup_multi
    JSR write_final_branch     ; apply precomputed branch (preserves X, Y)

.setup_multi:
    ; d = dx - dy → X (delta_minor still holds original dy here)
    LDA delta_major
    SEC
    SBC delta_minor
    TAX

    ; Adjust delta_minor: store dy-1 for the C=0 SBC trick
    ; (dy=0 stays 0: SBC 0 with C=0 gives d-1, correct BCS until phantom)
    LDA delta_minor
    BEQ .keep
    DEC delta_minor
.keep:

    CLC                     ; C=0 for pixel_loop entry

    ; Fall through to pixel_loop

pixel_loop:
    LDA (base),Y
    EOR mask_zp
    STA (base),Y
    TXA
    SBC delta_minor         ; C=0: A - (dy-1) - 1 = A - dy
    BCS .no_ystep
    ADC delta_major         ; d += dx; C=1 guaranteed (dx >= dy)
    DEY
    BPL .no_ystep
    DEC base+1
    LDY #7
.no_ystep:
    TAX                     ; save d; C=1 here (from BCS or ADC)
.smc_shift:
    LSR mask_zp             ; SMC: LSR $46 (fwd) / ASL $06 (rev)
.smc_branch:
    BCC pixel_loop              ; SMC'd: BCC pixel_loop + NOP (normal cols)
    NOP                         ;     or BBR(N) mask_zp, pixel_loop (final col)

    ; C=1 here from LSR/ASL (last bit shifted out) for normal cols
    LDA base
.smc_advance:
    ADC #7                  ; SMC: +7+C=+8 (fwd) / +$F7+C=-8 (rev)
    STA base
.smc_mask:
    LDA #$80                ; SMC: $80 (fwd) / $01 (rev)
    STA mask_zp

    INC cols_left           ; N/Z from result; C preserved
    BMI .resume
    BNE .complete
    JSR write_final_branch     ; apply precomputed branch (preserves C, X, Y)
.resume:
    CLC
    BRA pixel_loop
.complete:
    RTS                     ; line complete

;---------------------------------------
; Write precomputed branch to .smc_branch
; If final_branch = $90 (BCC sentinel), leaves BCC default in place.
; Preserves: C, X, Y
;---------------------------------------
write_final_branch:
    LDA final_branch
    BMI .done               ; bit 7 set → $90 (BCC)
    STA .smc_branch         ; byte 0: BBR opcode
    LDA #mask_zp
    STA .smc_branch + 1     ; byte 1: ZP address ($74)
    LDA #<(pixel_loop - (.smc_branch + 3))
    STA .smc_branch + 2     ; byte 2: backward offset to pixel_loop
.done:
    RTS
