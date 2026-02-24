; Zero page variables
base            = $70       ; 2 bytes - pointer to current position
delta_down      = $72       ; 1 byte - dy
delta_up        = $73       ; 1 byte - dx
cols_left       = $74       ; 1 byte - byte columns remaining after current
fixup_index     = $75       ; 1 byte - index into fixup_table
stripes_left    = $76       ; 1 byte - negated stripes remaining (INC toward zero)
const_ff        = $77       ; 1 byte - must be initialized to $FF by caller
final_bias      = $78       ; 1 byte - base offset for final stripe
ret_ptr         = $79       ; 2 bytes - pointer for exit fixup

; Entry points based on x0 & 7
entry_table:
    .word .bit7, .bit6, .bit5, .bit4, .bit3, .bit2, .bit1, .bit0

;---------------------------------------
; Main drawing routine
; Call setup_line first, then JMP to appropriate entry point
; Invariant: d is in X at each .bit<N> label
;---------------------------------------

draw_line:
.bit7:
    LDA (base),Y
.mask7:
    EOR #$80
    STA (base),Y
    TXA
    SBC delta_down
    BCS .step7
    ADC delta_up
    DEY
    BPL .step7
    JSR do_stripe_up
.step7:
    TAX
.bit6:
    LDA (base),Y
.mask6:
    EOR #$40
    STA (base),Y
    TXA
    SBC delta_down
    BCS .step6
    ADC delta_up
    DEY
    BPL .step6
    JSR do_stripe_up
.step6:
    TAX
.bit5:
    LDA (base),Y
.mask5:
    EOR #$20
    STA (base),Y
    TXA
    SBC delta_down
    BCS .step5
    ADC delta_up
    DEY
    BPL .step5
    JSR do_stripe_up
.step5:
    TAX
.bit4:
    LDA (base),Y
.mask4:
    EOR #$10
    STA (base),Y
    TXA
    SBC delta_down
    BCS .step4
    ADC delta_up
    DEY
    BPL .step4
    JSR do_stripe_up
.step4:
    TAX
.bit3:
    LDA (base),Y
.mask3:
    EOR #$08
    STA (base),Y
    TXA
    SBC delta_down
    BCS .step3
    ADC delta_up
    DEY
    BPL .step3
    JSR do_stripe_up
.step3:
    TAX
.bit2:
    LDA (base),Y
.mask2:
    EOR #$04
    STA (base),Y
    TXA
    SBC delta_down
    BCS .step2
    ADC delta_up
    DEY
    BPL .step2
    JSR do_stripe_up
.step2:
    TAX
.bit1:
    LDA (base),Y
.mask1:
    EOR #$02
    STA (base),Y
    TXA
    SBC delta_down
    BCS .step1
    ADC delta_up
    DEY
    BPL .step1
    JSR do_stripe_up
.step1:
    TAX
.bit0:
    LDA (base),Y
.mask0:
    EOR #$01
    STA (base),Y
    TXA
    SBC delta_down
    BCS .step0
    ADC delta_up
    DEY
    BPL .step0
    JSR do_stripe_up
.step0:
    DEC cols_left
    BMI .cols_done          ; no more columns
    TAX
    LDA base
.advance:
    ADC #7                  ; operand: 7 (fwd) / $F7 (rev); C=1 from draw loop
    STA base
    SEC
    JMP .bit7

.cols_done:
    LDX fixup_index
    LDA fixup_table,X
    EOR (base),Y
    STA (base),Y
    RTS

;---------------------------------------
; Stripe transition handler (always upward)
; d is in A on entry; returns d in A for caller's .step TAX
;---------------------------------------
do_stripe_up:
    INC stripes_left
    BPL .slow_path
    ; Normal stripe transition
    DEC base+1
    LDY #7
    RTS

.slow_path:
    BEQ .enter_final        ; zero: enter final stripe
    ; positive: fall through to exit

;---------------------------------------
; Line exit: fix up overrun pixels in last byte column.
; Uses JSR return address to find which bit we exited at.
; ret_addr - 15 = address of EOR operand in the calling block.
;---------------------------------------
.exit_line:
    PLA                     ; ret addr lo (C=1 from ADC delta_up)
    SBC #15                 ; offset to EOR operand
    STA ret_ptr
    PLA                     ; ret addr hi
    SBC #0                  ; propagate borrow
    STA ret_ptr+1
    LDA (ret_ptr)           ; read EOR operand = single-bit exit mask
    STA ret_ptr             ; save mask for reverse EOR
    ; Compute drawn_bits: (mask-1) EOR $FF = ~(mask-1) forward
    ;                     (mask-1) EOR mask = (mask<<1)-1 reverse
    DEC A
.smod_eor:
    EOR const_ff            ; SMC operand: const_ff=$77 (fwd) / ret_ptr=$79 (rev)
    LDX fixup_index
    AND fixup_table,X       ; isolate overrun bits within drawn region
    EOR (base)
    STA (base)
    RTS

;---------------------------------------
; Enter final stripe
;---------------------------------------
.enter_final:
    TAX                     ; save d — only this path clobbers A
    DEC base+1
    LDA base
    CLC
    ADC final_bias
    STA base
    LDA #8                  ; 8 not 7: C=0 after ADC, so SBC borrows 1
    SBC final_bias
    TAY
    TXA                     ; restore d to A
    ; C=1 from SBC (8 >= final_bias+1 always)
    RTS

;---------------------------------------
; Setup routine
; Inputs: x0, y0, x1, y1
; Returns: X=d, Y=row, C=1
;---------------------------------------
x0          = $80
y0          = $81
x1          = $82
y1          = $83
screen_page = $84           ; 1 byte - MSB of screen base address

setup_line:
    ; === Common preamble ===

    ; delta_up = dx
    LDA x1
    SEC
    SBC x0
    STA delta_up

    ; cols_left = ((x1 & $F8) - (x0 & $F8)) / 8
    LDA x1
    ORA #$07
    SBC x0                  ; C=1 from above (x1 >= x0)
    LSR
    LSR
    LSR
    STA cols_left

    ; Compute dy = y0 - y1, branch on direction
    LDA y0
    SEC
    SBC y1
    BCC .setup_reverse      ; y1 > y0: reverse

    ; Forward: A = y0 - y1 = |dy|
    STA delta_down

    ;===================================
    ; SETUP FORWARD (y0 >= y1, left-to-right)
    ;===================================
    ; fixup offset from forward table
    LDA x1
    AND #$07
    STA fixup_index

    ; Skip self-mod if already in forward state
    BIT .mask7+1
    BMI .setup_common       ; bit 7 set = $80 = already forward

    ; Self-modify EOR masks via LSR chain
    LDA #$80
    STA .mask7+1
    LSR
    STA .mask6+1
    LSR
    STA .mask5+1
    LSR
    STA .mask4+1
    LSR
    STA .mask3+1
    LSR
    STA .mask2+1
    LSR
    STA .mask1+1
    LSR
    STA .mask0+1

    ; Self-modify column advance +8
    LDA #7
    STA .advance+1

    ; Self-modify exit EOR for forward: EOR const_ff
    LDA #<const_ff
    STA .smod_eor+1

    BRA .setup_common

    ;===================================
    ; SETUP REVERSE (y1 > y0, right-to-left after swap)
    ;===================================
.setup_reverse:
    ; Reverse: A = y0 - y1 (negative), negate for |dy|
    EOR #$FF
    INC A
    STA delta_down

    ; fixup offset into reverse half of table
    LDA x0
    AND #$07
    ORA #$08
    STA fixup_index

    ; Swap y0 <-> y1
    LDA y0
    LDX y1
    STX y0
    STA y1

    ; Swap x1 into x0 and set entry bits for reversed draw order
    LDA x1
    EOR #$07
    STA x0

    ; Skip self-mod if already in reverse state
    BIT .mask7+1
    BPL .setup_common       ; bit 7 clear = $01 = already reverse

    ; Self-modify EOR masks via ASL chain
    LDA #$01
    STA .mask7+1
    ASL
    STA .mask6+1
    ASL
    STA .mask5+1
    ASL
    STA .mask4+1
    ASL
    STA .mask3+1
    ASL
    STA .mask2+1
    ASL
    STA .mask1+1
    ASL
    STA .mask0+1

    ; Self-modify column advance -8
    LDA #$F7                ; -8 unsigned (C=1 adds the extra 1)
    STA .advance+1

    ; Self-modify exit EOR for reverse: EOR ret_ptr (saved mask)
    LDA #<ret_ptr
    STA .smod_eor+1

    ; Fall through to .setup_common

    ;===================================
    ; SETUP COMMON (always upward after possible swap)
    ;===================================
.setup_common:
    ; d = dx - |dy| -> X
    LDA delta_up
    SEC
    SBC delta_down
    TAX

    ; base+1 = (y0/8) + screen_page; stash y0/8 in stripes_left
    LDA y0
    LSR
    LSR
    LSR
    STA stripes_left
    CLC
    ADC screen_page
    STA base+1

    LDA x0
    AND #$F8
    STA base

    ; final_bias = y1 & 7
    LDA y1
    AND #$07
    STA final_bias

    ; stripes_left = y1/8 - y0/8
    LDA y1
    LSR
    LSR
    LSR
    SEC
    SBC stripes_left
    STA stripes_left
    BMI .multi

    ; === Single stripe ===
    LDA base
    CLC
    ADC final_bias
    STA base

    ; Y = (y0 & 7) - final_bias
    LDA y0
    AND #$07
    SEC
    SBC final_bias
    TAY
    ; C=1 from SBC (y0&7 >= final_bias in single stripe)
    RTS

.multi:
    ; Y = y0 & 7
    LDA y0
    AND #$07
    TAY

    SEC
    RTS

;---------------------------------------
; Lookup tables for fixup masks
;---------------------------------------
fixup_table:
    .byte $7F, $3F, $1F, $0F, $07, $03, $01, $00
    .byte $00, $80, $C0, $E0, $F0, $F8, $FC, $FE
