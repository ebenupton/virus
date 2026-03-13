; test_line.s — Line rasterizer testbench
; Draws test lines one per frame for comparison against reference.
; Assembled with ca65: ca65 --cpu 65C02 test_line.s -o test_line.o
; Linked with ld65:    ld65 -C linker.cfg test_line.o -o test_line.bin

.setcpu "65C02"
.segment "CODE"

; === Hardware registers ===
CRTC_REG    = $FE00
CRTC_DAT    = $FE01
SYS_VIA_IFR = $FE4D

; === Zero page: rasterizer ($70-$84) ===
base            = $70       ; 2 bytes
delta_minor     = $72
delta_major     = $73
mask_zp         = $74
pixel_count     = $75
x0              = $80
y0              = $81
x1              = $82
y1              = $83
screen_page     = $84

; === Zero page: test harness ===
test_ptr        = $60       ; 2 bytes

; === Constants ===
SCREEN_W    = 128
SCREEN_H    = 160

MASK_LEFT   = $2A
MASK_RIGHT  = $15
MASK_TOGGLE = $3F

; =====================================================================
; Entry point ($0800)
; =====================================================================

entry:
    SEI

    ; Set CRTC to show $3000 (R12=$06, R13=$00)
    LDA #12
    STA CRTC_REG
    LDA #$06
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #$00
    STA CRTC_DAT

    ; Clear screen buffer at $3000 (40 pages: $3000-$57FF)
    LDA #0
    TAY
    LDX #$30
    STX base+1
    STY base
@clear_page:
    STA (base),Y
    INY
    BNE @clear_page
    INC base+1
    LDX base+1
    CPX #$58
    BNE @clear_page

    ; Set screen page
    LDA #$30
    STA screen_page

    ; Initialize test pointer
    LDA #<test_data
    STA test_ptr
    LDA #>test_data
    STA test_ptr+1

    ; Clear any pending vsync
    LDA #$02
    STA SYS_VIA_IFR

; === Main test loop ===
test_loop:
    ; Load endpoints from test table
    LDY #0
    LDA (test_ptr),Y
    CMP #$FF                ; sentinel?
    BNE @not_done
    JMP test_done
@not_done:
    STA x0
    INY
    LDA (test_ptr),Y
    STA y0
    INY
    LDA (test_ptr),Y
    STA x1
    INY
    LDA (test_ptr),Y
    STA y1

    ; --- Draw the line ---
    JSR init_base
    JSR draw_line
    ; Draw final pixel at endpoint
    LDA (base),Y
    EOR mask_zp
    STA (base),Y

    ; --- Wait for vsync (frame dump captures the drawn line) ---
    JSR wait_vsync

    ; --- Erase the line (XOR draw again) ---
    ; Reload x0, y0 from test table
    LDY #0
    LDA (test_ptr),Y
    STA x0
    INY
    LDA (test_ptr),Y
    STA y0
    JSR init_base
    JSR draw_line
    ; Erase final pixel
    LDA (base),Y
    EOR mask_zp
    STA (base),Y

    ; --- Advance to next test case (4 bytes) ---
    LDA test_ptr
    CLC
    ADC #4
    STA test_ptr
    BCC test_loop
    INC test_ptr+1
    JMP test_loop

test_done:
    ; Wait forever
    JMP test_done

; =====================================================================
; Wait for one vsync
; =====================================================================
wait_vsync:
    ; Clear pending
    LDA #$02
    STA SYS_VIA_IFR
@wait:
    LDA SYS_VIA_IFR
    AND #$02
    BEQ @wait
    RTS

; =====================================================================
; Line rasterizer — copied from game_new_full.s (optimized shallow loop)
; =====================================================================

mask_init_table:
    .byte MASK_LEFT, MASK_RIGHT

; X-direction SMC tables (index 0 = right-going, 1 = left-going)
x_smc_p1:     .byte MASK_LEFT, MASK_RIGHT
x_smc_p2:     .byte MASK_RIGHT, MASK_LEFT
x_smc_col:    .byte $08, $F8
x_smc_bra:    .byte $90, $B0       ; BCC / BCS opcode
x_smc_carry:  .byte $E6, $C6       ; INC zp / DEC zp opcode

draw_line:
    PHY                     ; save screen sub-row

    ; --- Compute |dx| and set X-direction SMC ---
    LDA x1
    SEC
    SBC x0
    BEQ @dx_zero
    BCS @x_right

    ; X going left: |dx| = x0 - x1
    EOR #$FF
    INC A
    LDX #1
    BRA @x_setup

@x_right:
    LDX #0

@x_setup:
    PHA                     ; save |dx|
    LDA x_smc_p1,X
    STA smc_su_p1+1
    STA smc_sd_p1+1
    STA smc_t_boundary+1
    LDA x_smc_p2,X
    STA smc_su_p2+1
    STA smc_sd_p2+1
    LDA x_smc_col,X
    STA smc_su_col+1
    STA smc_sd_col+1
    DEC A
    STA smc_t_col_adv+1
    LDA x_smc_bra,X
    STA smc_su_bcc
    STA smc_sd_bcc
    LDA x_smc_carry,X
    STA smc_su_carry
    STA smc_sd_carry
    BRA @do_dy

@dx_zero:
    LDA #0
    PHA

@do_dy:
    ; --- Compute |dy| and set Y-direction SMC ---
    LDA y0
    SEC
    SBC y1
    BEQ @dy_zero
    BCS @y_up

    ; Y going down (y0 < y1)
    EOR #$FF
    INC A
    TAY
    LDA #$C8                ; INY opcode
    STA smc_t_ystep
    LDA #$08
    STA smc_t_ylimit+1
    LDA #$E6                ; INC zp opcode
    STA smc_t_row1
    STA smc_t_row2
    LDA #$00
    STA smc_t_yreset+1
    BRA @route

@y_up:
    TAY
    LDA #$88                ; DEY opcode
    STA smc_t_ystep
    LDA #$FF
    STA smc_t_ylimit+1
    LDA #$C6                ; DEC zp opcode
    STA smc_t_row1
    STA smc_t_row2
    LDA #$07
    STA smc_t_yreset+1
    BRA @route

@dy_zero:
    LDY #0

@route:
    PLA                     ; A = |dx|
    BNE @has_len
    CPY #0
    BEQ @zero_line

@has_len:
    STY delta_minor
    CMP delta_minor
    BCS @shallow

    ; --- STEEP ---
    STA delta_minor
    STY pixel_count
    STY delta_major
    PLY
    JMP steep_entry

@shallow:
    ; --- SHALLOW ---
    STA pixel_count
    STA delta_major
    STY delta_minor
    PLY
    ; Bresenham error init
    LDA delta_major
    SEC
    SBC delta_minor
    TAX
    ; Route by Y direction
    LDA y0
    CMP y1
    BCS su_align
    ; Y down
    LDA mask_zp
    CMP smc_sd_p1+1
    SEC
    BEQ sd_pair_loop
    BRA sd_p2

@zero_line:
    PLY
    RTS

; === SHALLOW Y-down pair loop ===

sd_pair_loop:
    LDA (base),Y
smc_sd_p1:
    EOR #MASK_LEFT
    STA (base),Y
    TXA
    SBC delta_minor
    BCS sd_no_y1
    ADC delta_major
    INY
    CPY #8
    SEC
    BNE sd_no_y1
    INC base+1
    INC base+1
    LDY #0
sd_no_y1:
    TAX
    DEC pixel_count
    BEQ sd_done
sd_p2:
    LDA (base),Y
smc_sd_p2:
    EOR #MASK_RIGHT
    STA (base),Y
    TXA
    SBC delta_minor
    BCS sd_no_y2
    ADC delta_major
    INY
    CPY #8
    BNE sd_no_y2
    INC base+1
    INC base+1
    LDY #0
sd_no_y2:
    TAX
    CLC
    LDA base
smc_sd_col:
    ADC #$08
    STA base
smc_sd_bcc:
    BCC sd_no_page
smc_sd_carry:
    INC base+1
sd_no_page:
    SEC
    DEC pixel_count
    BNE sd_pair_loop
sd_done:
    BRA s_exit

; === SHALLOW Y-up pair loop ===

su_align:
    LDA mask_zp
    CMP smc_su_p1+1
    SEC
    BEQ su_pair_loop
    BRA su_p2

su_pair_loop:
    LDA (base),Y
smc_su_p1:
    EOR #MASK_LEFT
    STA (base),Y
    TXA
    SBC delta_minor
    BCS su_no_y1
    ADC delta_major
    SEC
    DEY
    BPL su_no_y1
    DEC base+1
    DEC base+1
    LDY #7
su_no_y1:
    TAX
    DEC pixel_count
    BEQ su_done
su_p2:
    LDA (base),Y
smc_su_p2:
    EOR #MASK_RIGHT
    STA (base),Y
    TXA
    SBC delta_minor
    BCS su_no_y2
    ADC delta_major
    DEY
    BPL su_no_y2
    DEC base+1
    DEC base+1
    LDY #7
su_no_y2:
    TAX
    CLC
    LDA base
smc_su_col:
    ADC #$08
    STA base
smc_su_bcc:
    BCC su_no_page
smc_su_carry:
    INC base+1
su_no_page:
    SEC
    DEC pixel_count
    BNE su_pair_loop
su_done:

s_exit:
    LDA x1
    LSR A
    LDA #MASK_LEFT
    BCC @s_set
    LDA #MASK_RIGHT
@s_set:
    STA mask_zp
    RTS

; === STEEP pixel loop ===

steep_entry:
    LDA delta_major
    SEC
    SBC delta_minor
    TAX
    SEC

t_pixel_loop:
    LDA (base),Y
    EOR mask_zp
    STA (base),Y

    TXA
    SBC delta_minor
    BCS t_no_x
    ADC delta_major
    PHA
    LDA mask_zp
    EOR #MASK_TOGGLE
    STA mask_zp
smc_t_boundary:
    CMP #MASK_LEFT
    BNE t_xdone_pla
    LDA base
smc_t_col_adv:
    ADC #$07
    STA base
    BCC t_no_carry
    LDA smc_t_col_adv+1
    BMI t_xdone_pla
    INC base+1
    BRA t_xdone_pla
t_no_carry:
    LDA smc_t_col_adv+1
    BPL t_xdone_pla
    DEC base+1
t_xdone_pla:
    PLA
t_no_x:
    TAX

smc_t_ystep:
    DEY
smc_t_ylimit:
    CPY #$FF
    BNE t_no_row
smc_t_row1:
    DEC base+1
smc_t_row2:
    DEC base+1
smc_t_yreset:
    LDY #7
t_no_row:
    DEC pixel_count
    SEC
    BNE t_pixel_loop
    RTS

; =====================================================================
; init_base: Compute screen address for pixel (x0, y0)
; =====================================================================
init_base:
    LDA x0
    AND #$01
    TAX
    LDA mask_init_table,X
    STA mask_zp

    LDA screen_page
    STA base+1
    LDA x0
    AND #$40
    BEQ @ib_no_carry
    INC base+1
@ib_no_carry:
    LDA y0
    AND #$F8
    LSR A
    LSR A
    CLC
    ADC base+1
    STA base+1

    LDA x0
    AND #$FE
    ASL A
    ASL A
    STA base

    LDA y0
    AND #$07
    TAY
    RTS

; =====================================================================
; Test data — generated by testbench.py
; =====================================================================
.include "test_data.inc"
