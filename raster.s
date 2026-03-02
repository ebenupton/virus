; raster.s — Combined Bresenham line rasterizer for 65C02
; Unified draw_line entry dispatches to shallow (dx >= |dy|) or steep (|dy| > dx).
;
; Shallow: major axis = X (columns), minor axis = Y (rows).
;   Rerolled inner loop with LSR/ASL shift + BBR/BCC termination.
; Steep: major axis = Y (rows), minor axis = X (bit positions).
;   Rolled inner loop with DEY + BPL termination.
;
; Shared: init_base subroutine, mask_init_table, ZP layout.

; Zero page variables
base            = $70       ; 2 bytes - pointer to current position
delta_minor     = $72       ; 1 byte — dy-1 (shallow) / dx (steep)
delta_major     = $73       ; 1 byte — dx (shallow) / |dy| (steep)
mask_zp         = $74       ; 1 byte — current pixel bitmask
cols_left       = $75       ; shallow: negated column counter
stripes_left    = $75       ; steep:   negated stripe counter (same addr)
final_branch    = $76       ; shallow: precomputed BBR/BCC opcode
final_bias      = $76       ; steep:   y_end & 7 (same addr)
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

.ifndef UNROLL_SHALLOW
; BBR opcode tables indexed by x1 & 7 (rolled shallow path only).
; $90 (BCC) sentinel shared: fwd_branch_table[7] = rev_branch_table[0].
fwd_branch_table:
    .byte opBBR6, opBBR5, opBBR4, opBBR3, opBBR2, opBBR1, opBBR0
rev_branch_table:
    .byte  opBCC, opBBR7, opBBR6, opBBR5, opBBR4, opBBR3, opBBR2, opBBR1
.endif

;=======================================
; Entry point
; Inputs: x0, y0, x1, y1, screen_page
;=======================================

draw_line:
    ; Ensure x1 >= x0 (swap endpoints if needed for left-facing lines)
    LDA x1
    CMP x0
    BCS .no_swap
    LDX x0
    STA x0
    STX x1
    LDA y0
    LDX y1
    STA y1
    STX y0
.no_swap:

    ; Compute |dy| = |y0 - y1|
    LDA y0
    SEC
    SBC y1
    BCS .abs_dy
    EOR #$FF
    INC A
.abs_dy:
    ; A = |dy|
    TAY                     ; Y = |dy|
    ; Compute dx = x1 - x0
    LDA x1
    SEC
    SBC x0                  ; A = dx
    ; Dispatch: dx >= |dy| → shallow, else steep
    STY delta_minor         ; temp stash |dy| (shallow keeps it)
    CMP delta_minor         ; dx vs |dy|
    BCS shallow_setup       ; dx >= |dy|
    JMP steep_setup         ; |dy| > dx

.ifdef UNROLL_SHALLOW

;=======================================
; SHALLOW PATH — unrolled, 8 pixels/byte
;=======================================

smc_rts_needed = final_branch           ; reuse ZP $76

;--- Macro: one unrolled pixel iteration ---
.macro UPIX n, default_eor
.ident(.concat("s_upix", .string(n))):
    LDA (base),Y
.ident(.concat("smc_eor_", .string(n))):
    EOR #default_eor
    STA (base),Y
    TXA
    SBC delta_minor
    BCS :+
    ADC delta_major
    DEY
    BPL :+
    DEC base+1
    LDY #7
:   TAX
.endmacro

;--- Entry/exit address tables ---
su_entry_lo:
    .byte <(s_upix0-1), <(s_upix1-1), <(s_upix2-1), <(s_upix3-1)
    .byte <(s_upix4-1), <(s_upix5-1), <(s_upix6-1), <(s_upix7-1)
su_entry_hi:
    .byte >(s_upix0-1), >(s_upix1-1), >(s_upix2-1), >(s_upix3-1)
    .byte >(s_upix4-1), >(s_upix5-1), >(s_upix6-1), >(s_upix7-1)

su_rts_lo:
    .byte <s_upix1, <s_upix2, <s_upix3, <s_upix4
    .byte <s_upix5, <s_upix6, <s_upix7, <s_upix0
su_rts_hi:
    .byte >s_upix1, >s_upix2, >s_upix3, >s_upix4
    .byte >s_upix5, >s_upix6, >s_upix7, >s_upix0

;--- Write RTS to termination pixel if needed ---
su_write_rts:
    LDA smc_rts_needed
    BEQ :+
smc_su_rts_sta:
    STA $FFFF                           ; SMC: target pixel address
:   RTS

;--- Shallow setup (unrolled) ---
shallow_setup:
    ; Entry: A = dx, Y = |dy|, delta_minor = |dy|, C=1 from CMP
    STA delta_major

    ; cols_left = -((x1>>3) - (x0>>3))   [C=1 from CMP]
    LDA x1
    ORA #$07
    SBC x0                              ; C=1: exact (x1|7) - x0
    LSR
    LSR
    LSR                                 ; = (x1>>3) - (x0>>3)
    EOR #$FF
    INC A
    STA cols_left

    ; Restore previous RTS overwrite
    LDA #$B1                            ; LDA (zp),Y opcode
su_prev_restore:
    STA s_upix0                         ; SMC: default harmless (already $B1)

    ; Branch on y-direction
    LDA y0
    CMP y1
    BCC .su_reverse

    ;=== FORWARD (y0 >= y1) ===
    LDA x1
    AND #$07
    STA smc_rts_needed                  ; rts_idx → $76 (temp)

    LDA x0
    AND #$07
    PHA                                 ; entry_idx on stack

    ; SMC EOR immediates (skip if already forward: bit 7 set = $80)
    BIT smc_eor_0+1
    BMI .su_common                      ; already forward → skip
    LDA #$80
    STA smc_eor_0+1
    LSR A
    STA smc_eor_1+1
    LSR A
    STA smc_eor_2+1
    LSR A
    STA smc_eor_3+1
    LSR A
    STA smc_eor_4+1
    LSR A
    STA smc_eor_5+1
    LSR A
    STA smc_eor_6+1
    LSR A
    STA smc_eor_7+1

    LDA #$07
    STA smc_su_advance+1                ; column advance = +8

    BRA .su_common

    ;=== REVERSE (y1 > y0) ===
.su_reverse:
    ; rts_idx = 7 - (x0 & 7)  [original x0 before swap]
    LDA x0
    AND #$07
    EOR #$07
    STA smc_rts_needed                  ; rts_idx → $76 (temp)

    ; entry_idx = 7 - (x1 & 7)
    LDA x1
    AND #$07
    EOR #$07
    PHA                                 ; entry_idx on stack

    ; Swap endpoints: draw from (x1, y1) backward
    LDA x1
    STA x0
    LDA y1
    STA y0

    ; SMC EOR immediates (skip if already reverse: bit 7 clear = $01)
    BIT smc_eor_0+1
    BPL .su_common                      ; already reverse → skip
    LDA #$01
    STA smc_eor_0+1
    ASL A
    STA smc_eor_1+1
    ASL A
    STA smc_eor_2+1
    ASL A
    STA smc_eor_3+1
    ASL A
    STA smc_eor_4+1
    ASL A
    STA smc_eor_5+1
    ASL A
    STA smc_eor_6+1
    ASL A
    STA smc_eor_7+1

    LDA #$F7
    STA smc_su_advance+1                ; column advance = -8

    ; Fall through to .su_common

.su_common:
    JSR init_base                       ; sets base, Y from x0/y0

    ; Set up RTS/restore targets from rts_idx
    LDX smc_rts_needed                  ; rts_idx (still in $76)
    LDA su_rts_lo,X
    STA smc_su_rts_sta+1
    STA smc_su_rts_restore+1
    STA su_prev_restore+1
    LDA su_rts_hi,X
    STA smc_su_rts_sta+2
    STA smc_su_rts_restore+2
    STA su_prev_restore+2

    ; smc_rts_needed = $60 if RTS termination needed, else $00
    LDA #$60
    CPX #7
    BNE :+
    LDA #$00
:   STA smc_rts_needed

    ; Single-column: write RTS now if needed
    LDA cols_left
    BNE .su_multi
    JSR su_write_rts

.su_multi:
    ; Computed entry: push entry_addr-1 (before d, so Y is preserved)
    PLA                                 ; entry_idx from stack
    TAX
    LDA su_entry_hi,X
    PHA
    LDA su_entry_lo,X
    PHA

    ; d = dx - dy → X
    LDA delta_major
    SEC
    SBC delta_minor
    TAX

    ; X = d, Y = screen row (from init_base, preserved)
    SEC                                 ; C=1 invariant for SBC
    RTS                                 ; pops entry_addr-1, jumps in

;--- Unrolled pixel loop (8 iterations, forward defaults) ---
    UPIX 0, $80
    UPIX 1, $40
    UPIX 2, $20
    UPIX 3, $10
    UPIX 4, $08
    UPIX 5, $04
    UPIX 6, $02
    UPIX 7, $01

;--- Column transition (falls through from s_upix7) ---
    ; C=1 from Bresenham step (guaranteed: BCS or ADC)
    LDA base
smc_su_advance:
    ADC #$07                            ; SMC: +8 fwd / -8 rev (C=1)
    STA base
    INC cols_left
    BMI .su_resume                      ; more normal columns
    BNE .su_complete                    ; done (cols_left > 0)
    ; cols_left == 0: entering final column
    JSR su_write_rts
.su_resume:
    SEC
    JMP s_upix0
.su_complete:
    LDA #$B1                            ; restore RTS overwrite
smc_su_rts_restore:
    STA $FFFF                           ; SMC: same target as smc_su_rts_sta
    RTS

.else

;=======================================
; SHALLOW PATH — major axis X, minor axis Y
;=======================================

shallow_setup:
    ; Entry: A = dx, Y = |dy|, delta_minor = |dy|, C=1 from CMP
    STA delta_major

    ; cols_left = -((x1>>3) - (x0>>3))   [C=1 from CMP]
    LDA x1
    ORA #$07
    SBC x0                  ; C=1: exact (x1|7) - x0
    LSR
    LSR
    LSR                     ; (x1>>3) - (x0>>3)
    EOR #$FF
    INC A
    STA cols_left

    ; Branch on y-direction
    LDA y0
    CMP y1
    BCC .s_setup_reverse    ; y1 > y0

    ;=== FORWARD (y0 >= y1) ===
    ; delta_minor = |dy| already correct from entry

    ; final_branch = fwd_branch_table[x1 & 7]
    LDA x1
    AND #$07
    TAX
    LDA fwd_branch_table,X
    STA final_branch

    LDA #opLSRzp
    LDX #$80
    LDY #$07

    BRA .s_setup_common

    ;=== REVERSE (y1 > y0) ===
.s_setup_reverse:
    ; delta_minor = |dy| already correct from entry

    ; final_branch = rev_branch_table[x0 & 7]  (original x0 = line endpoint)
    LDA x0
    AND #$07
    TAX
    LDA rev_branch_table,X
    STA final_branch

    ; Swap endpoints: draw from (x1,y1) backward
    LDA x1
    STA x0
    LDA y1
    STA y0

    LDA #opASLzp
    LDX #$01
    LDY #$F7

    ; Fall through to .s_setup_common

    ;=== COMMON ===
.s_setup_common:
    STA .smc_s_shift
    STX .smc_s_mask + 1
    STY .smc_s_advance + 1

    JSR init_base           ; sets mask_zp, base, Y from x0/y0

    ; Write BCC default to .smc_s_branch (fast path for normal columns)
    LDA #opBCC
    STA .smc_s_branch
    LDA #<(s_pixel_loop - (.smc_s_branch + 2))
    STA .smc_s_branch + 1
    LDA #opNOP
    STA .smc_s_branch + 2

    ; Single-column override: write final branch for immediate termination
    LDA cols_left
    BNE .s_setup_multi
    JSR s_write_final_branch

.s_setup_multi:
    ; d = dx - dy
    LDA delta_major
    SEC
    SBC delta_minor
    TAX

    ; Adjust delta_minor: store dy-1 for the C=0 SBC trick
    ; (dy=0 stays 0: SBC 0 with C=0 gives d-1, correct BCS until phantom)
    LDA delta_minor
    BEQ .s_keep
    DEC delta_minor
.s_keep:
    CLC                     ; C=0 for pixel_loop entry

    ; Fall through to s_pixel_loop

;---------------------------------------
; Shallow inner loop (rolled)
; Invariant: C=0, d in X
;---------------------------------------
s_pixel_loop:
    LDA (base),Y
    EOR mask_zp
    STA (base),Y
    TXA
    SBC delta_minor         ; C=0: A - (dy-1) - 1 = A - dy
    BCS .s_no_ystep
    ADC delta_major         ; d += dx; C=1 guaranteed (dx >= dy)
    DEY
    BPL .s_no_ystep
    DEC base+1
    LDY #7
.s_no_ystep:
    TAX                     ; save d; C=1 here (from BCS or ADC)
.smc_s_shift:
    LSR mask_zp             ; SMC: LSR (fwd) / ASL (rev)
.smc_s_branch:
    BCC s_pixel_loop        ; SMC: BCC+NOP (normal) or BBR(N) (final)
    NOP

    ; Column transition: C=1 from last-bit shift-out
    LDA base
.smc_s_advance:
    ADC #7                  ; SMC: +7+C=+8 (fwd) / +$F7+C=-8 (rev)
    STA base
.smc_s_mask:
    LDA #$80                ; SMC: $80 (fwd) / $01 (rev)
    STA mask_zp

    INC cols_left
    BMI .s_resume
    BNE .s_complete
    JSR s_write_final_branch
.s_resume:
    CLC
    BRA s_pixel_loop
.s_complete:
    RTS

;---------------------------------------
; Write precomputed branch to .smc_s_branch
; If final_branch = $90 (BCC), leaves BCC default in place.
; Preserves: C, X, Y
;---------------------------------------
s_write_final_branch:
    LDA final_branch
    BMI .s_wfb_done         ; bit 7 set → $90 (BCC sentinel)
    STA .smc_s_branch       ; byte 0: BBR opcode
    LDA #mask_zp
    STA .smc_s_branch + 1   ; byte 1: ZP address ($74)
    LDA #<(s_pixel_loop - (.smc_s_branch + 3))
    STA .smc_s_branch + 2   ; byte 2: backward offset
.s_wfb_done:
    RTS

.endif

;=======================================
; STEEP PATH — major axis Y, minor axis X
;=======================================

steep_setup:
    ; Entry: A = dx, Y = |dy|, delta_minor = |dy| (will be overwritten)
    STA delta_minor         ; delta_minor = dx
    STY delta_major         ; delta_major = |dy|

    ; Branch on y-direction
    LDA y0
    CMP y1
    BCC .t_setup_reverse    ; y1 > y0

    ;=== FORWARD (y0 >= y1) ===
    ; [C=1 from CMP, preserved through LDA/AND/STA/LDA/ORA]

    ; final_bias = y1 & 7
    LDA y1
    AND #$07
    STA final_bias

    ; stripes_left = -((y0>>3) - (y1>>3))
    LDA y0
    ORA #$07
    SBC y1                  ; C=1: exact (y0|7) - y1
    LSR
    LSR
    LSR
    EOR #$FF
    INC A
    STA stripes_left

    LDA #opLSRzp
    LDX #$80
    LDY #$07

    BRA .t_setup_common

    ;=== REVERSE (y1 > y0) ===
.t_setup_reverse:
    ; final_bias = y0 & 7
    LDA y0
    AND #$07
    STA final_bias

    ; stripes_left = -((y1>>3) - (y0>>3))
    LDA y1
    ORA #$07
    SEC                     ; explicit SEC needed (C=0 from CMP)
    SBC y0
    LSR
    LSR
    LSR
    EOR #$FF
    INC A
    STA stripes_left

    ; Swap endpoints: draw from (x1,y1) downward
    LDA x1
    STA x0
    LDA y1
    STA y0

    LDA #opASLzp
    LDX #$01
    LDY #$F7

    ; Fall through to .t_setup_common

    ;=== COMMON ===
.t_setup_common:
    STA .smc_t_shift
    STX .smc_t_mask + 1
    STY .smc_t_col_advance + 1

    JSR init_base           ; sets mask_zp, base, Y from x0/y0

    ; Single-stripe check: if stripes_left = 0, apply final_bias offset
    LDA stripes_left
    BNE .t_setup_multi
    LDA base
    CLC
    ADC final_bias
    STA base
    TYA
    SEC
    SBC final_bias
    TAY
.t_setup_multi:
    ; d = dy - dx
    LDA delta_major
    SEC
    SBC delta_minor
    TAX
    ; C=1 guaranteed (dy > dx)

    ; Fall through to t_pixel_loop

;---------------------------------------
; Steep inner loop (rolled)
; Invariant: C=1, d in X
;---------------------------------------
t_pixel_loop:
    LDA (base),Y
    EOR mask_zp
    STA (base),Y
    TXA
    SBC delta_minor         ; C=1: d - dx
    BCS .t_no_xstep         ; d >= 0: no x-step
    ADC delta_major         ; d += dy, C=1 guaranteed (dy > dx)
.smc_t_shift:
    LSR mask_zp             ; SMC: LSR (fwd) / ASL (rev)
    BCC .t_xdone            ; C=0: no column wrap
    ; Column crossing (d in A, C=1 from shift-out)
    PHA
    LDA base
.smc_t_col_advance:
    ADC #$07                ; SMC: +7+C=+8 (fwd) / +$F7+C=-8 (rev)
    STA base
.smc_t_mask:
    LDA #$80                ; SMC: $80 (fwd) / $01 (rev)
    STA mask_zp
    PLA
.t_xdone:
    SEC                     ; restore C=1
.t_no_xstep:
    TAX
    DEY
    BPL t_pixel_loop

    ;--- Stripe transition ---
    INC stripes_left
    BMI .t_normal_stripe
    BNE .t_complete
    ; Zero: entering final stripe
    DEC base+1
    LDA base
    CLC
    ADC final_bias
    STA base
    LDA #7
    SEC
    SBC final_bias
    TAY
    SEC                     ; C=1 for SBC
    BRA t_pixel_loop

.t_normal_stripe:
    DEC base+1
    LDY #7
    SEC
    BRA t_pixel_loop

.t_complete:
    RTS

;=======================================
; Shared subroutine: init_base
; Sets mask_zp, base, Y from current x0/y0.
; Clobbers: A, X, Y
;=======================================
init_base:
    LDA x0
    AND #$07
    TAX
    LDA mask_init_table,X
    STA mask_zp
    LDA y0
    LSR
    LSR
    LSR
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
