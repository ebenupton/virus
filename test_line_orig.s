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
chain_idx       = $62
seg_count       = $63
saved_y         = $64

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

; === Main test loop — draws chains ===
; Format: [num_points] [x0 y0] [x1 y1] [x2 y2] ... [sentinel $FF]
; Each chain: init_base at first point, then draw_line chained for each segment,
; final pixel at end. One vsync per chain to capture the frame.
test_loop:
    ; Read chain header: number of points
    LDY #0
    LDA (test_ptr),Y
    CMP #$FF
    BNE @has_chain
    JMP test_done
@has_chain:
    ; A = num_points, segments = num_points - 1
    SEC
    SBC #1
    STA seg_count

    ; Load first point
    LDY #1
    LDA (test_ptr),Y
    STA x0
    INY
    LDA (test_ptr),Y
    STA y0
    JSR init_base           ; set base, Y, mask_zp from (x0, y0)
    LDA #3
    STA chain_idx           ; byte offset of next endpoint in chain

@seg_loop:
    ; Call init_base before every segment (no chaining)
    JSR init_base
    ; Load next endpoint
    LDY chain_idx
    LDA (test_ptr),Y
    STA x1
    INY
    LDA (test_ptr),Y
    STA y1
    INY
    STY chain_idx
    JSR draw_line           ; draw segment from fresh init_base
    ; Endpoint becomes start of next segment
    LDA x1
    STA x0
    LDA y1
    STA y0
    DEC seg_count
    BNE @seg_loop

    ; Draw final pixel of chain
    LDA (base),Y
    EOR mask_zp
    STA (base),Y

    ; --- Wait for vsync (frame dump captures the drawn chain) ---
    JSR wait_vsync

    ; --- Clear screen for next chain ---
    JSR clear_screen
    JSR wait_vsync          ; ensure blank is captured
    JSR wait_vsync          ; extra sync for safety

    ; --- Advance test_ptr past this chain ---
    ; Chain size = 1 (header) + num_points * 2
    LDY #0
    LDA (test_ptr),Y        ; num_points
    ASL A                    ; * 2
    INC A                    ; + 1 (header byte)
    CLC
    ADC test_ptr
    STA test_ptr
    BCS @ptr_carry
    JMP test_loop
@ptr_carry:
    INC test_ptr+1
    JMP test_loop

test_done:
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
; Clear screen buffer at $3000-$57FF
; =====================================================================
clear_screen:
    LDA #0
    TAY
    LDX #$30
    STX base+1
    STY base
@loop:
    STA (base),Y
    INY
    BNE @loop
    INC base+1
    LDX base+1
    CPX #$58
    BNE @loop
    RTS

; =====================================================================
; Line rasterizer — ORIGINAL single-pixel loop from baseline
; =====================================================================

mask_init_table:
    .byte MASK_LEFT, MASK_RIGHT

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
    PHA                     ; save |dx|
    LDA #MASK_RIGHT
    STA smc_s_mask+1
    STA smc_s_eor+1
    STA smc_t_boundary+1
    LDA #$F8
    STA smc_s_advance+1
    LDA #$F7
    STA smc_t_col_adv+1
    BRA @do_dy

@x_right:
    ; X going right: |dx| = x1 - x0
    PHA                     ; save |dx|
    LDA #MASK_LEFT
    STA smc_s_mask+1
    STA smc_s_eor+1
    STA smc_t_boundary+1
    LDA #$08
    STA smc_s_advance+1
    LDA #$07
    STA smc_t_col_adv+1
    BRA @do_dy

@dx_zero:
    LDA #0
    PHA                     ; push 0 for |dx|

@do_dy:
    ; --- Compute |dy| and set Y-direction SMC ---
    LDA y0
    SEC
    SBC y1
    BEQ @dy_zero
    BCS @y_up

    ; Y going down (y0 < y1): |dy| = y1 - y0
    EOR #$FF
    INC A
    TAY                     ; Y = |dy|
    LDA #$C8                ; INY opcode
    STA smc_s_ystep
    STA smc_t_ystep
    LDA #$08
    STA smc_s_ylimit+1
    STA smc_t_ylimit+1
    LDA #$E6                ; INC zp opcode
    STA smc_s_row1
    STA smc_s_row2
    STA smc_t_row1
    STA smc_t_row2
    LDA #$00
    STA smc_s_yreset+1
    STA smc_t_yreset+1
    BRA @route

@y_up:
    ; Y going up (y0 > y1): |dy| = y0 - y1
    TAY                     ; Y = |dy|
    LDA #$88                ; DEY opcode
    STA smc_s_ystep
    STA smc_t_ystep
    LDA #$FF
    STA smc_s_ylimit+1
    STA smc_t_ylimit+1
    LDA #$C6                ; DEC zp opcode
    STA smc_s_row1
    STA smc_s_row2
    STA smc_t_row1
    STA smc_t_row2
    LDA #$07
    STA smc_s_yreset+1
    STA smc_t_yreset+1
    BRA @route

@dy_zero:
    LDY #0                  ; |dy| = 0

@route:
    ; Y = |dy|, stack: |dx|, sub-row
    PLA                     ; A = |dx|
    BNE @has_len
    CPY #0
    BEQ @zero_line

@has_len:
    ; Shallow if |dx| >= |dy|, steep otherwise
    STY delta_minor
    CMP delta_minor
    BCS @shallow

    ; --- STEEP: |dy| > |dx|, major = Y, minor = X ---
    STA delta_minor
    STY pixel_count
    STY delta_major
    PLY                     ; restore screen sub-row
    JMP steep_entry

@shallow:
    ; --- SHALLOW: |dx| >= |dy|, major = X, minor = Y ---
    STA pixel_count
    STA delta_major
    STY delta_minor
    PLY                     ; restore screen sub-row
    JMP shallow_entry

@zero_line:
    PLY                     ; restore sub-row (balance stack)
    RTS

; === SHALLOW pixel loop (original single-pixel) ===

shallow_entry:
    LDA delta_major
    SEC
    SBC delta_minor
    TAX                     ; X = Bresenham error
    SEC

s_pixel_loop:
    LDA (base),Y
    EOR mask_zp
    STA (base),Y

    ; Bresenham Y step
    TXA
    SBC delta_minor
    BCS s_no_y
    ADC delta_major
smc_s_ystep:
    DEY                     ; SMC: DEY ($88) or INY ($C8)
smc_s_ylimit:
    CPY #$FF                ; SMC: $FF (up) or $08 (down)
    BNE s_no_y
smc_s_row1:
    DEC base+1              ; SMC: DEC ($C6) or INC ($E6)
smc_s_row2:
    DEC base+1
smc_s_yreset:
    LDY #7                  ; SMC: 7 (up) or 0 (down)
s_no_y:
    TAX

    ; Advance X: toggle mask, check boundary
    LDA mask_zp
    EOR #MASK_TOGGLE
    STA mask_zp
smc_s_eor:
    EOR #MASK_LEFT          ; SMC: MASK_LEFT (right) or MASK_RIGHT (left)
    BEQ s_boundary

    ; No boundary — loop
    DEC pixel_count
    SEC
    BNE s_pixel_loop
    RTS

s_boundary:
    ; Column boundary: advance to next byte column
    CLC
    LDA base
smc_s_advance:
    ADC #$08                ; SMC: $08 (right) or $F8 (left)
    STA base
    BCC s_no_carry
    LDA smc_s_advance+1
    BMI s_col_done
    INC base+1
    BRA s_col_done
s_no_carry:
    LDA smc_s_advance+1
    BPL s_col_done
    DEC base+1
s_col_done:
smc_s_mask:
    LDA #MASK_LEFT          ; SMC: MASK_LEFT (right) or MASK_RIGHT (left)
    STA mask_zp
    DEC pixel_count
    SEC
    BNE s_pixel_loop
    RTS

; === STEEP pixel loop ===

steep_entry:
    LDA delta_major
    SEC
    SBC delta_minor
    TAX                     ; X = Bresenham error
    SEC

t_pixel_loop:
    LDA (base),Y
    EOR mask_zp
    STA (base),Y

    ; Bresenham X step
    TXA
    SBC delta_minor
    BCS t_no_x
    ADC delta_major
    PHA
    LDA mask_zp
    EOR #MASK_TOGGLE
    STA mask_zp
smc_t_boundary:
    CMP #MASK_LEFT          ; SMC: MASK_LEFT (right) or MASK_RIGHT (left)
    BNE t_xdone_pla
    ; Column boundary (C=1 from CMP match)
    LDA base
smc_t_col_adv:
    ADC #$07                ; SMC: $07 (right) or $F7 (left), C=1
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

    ; Y step (always, major axis)
smc_t_ystep:
    DEY                     ; SMC: DEY ($88) or INY ($C8)
smc_t_ylimit:
    CPY #$FF                ; SMC: $FF (up) or $08 (down)
    BNE t_no_row
smc_t_row1:
    DEC base+1              ; SMC: DEC ($C6) or INC ($E6)
smc_t_row2:
    DEC base+1
smc_t_yreset:
    LDY #7                  ; SMC: 7 (up) or 0 (down)
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
