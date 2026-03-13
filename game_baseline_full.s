; game.s — Static 8x8 perspective grid for BBC Micro
; Assembled with ca65: ca65 --cpu 65C02 game.s -o game.o
; Linked with ld65:    ld65 -C linker.cfg game.o -o game.bin
;
; Loads and runs at $0800. Double-buffered at $3000/$5800 (10K each).
; MODE 2-like video: 128x160, 4bpp, 512-byte stripes.
; XOR rendering for flicker-free erase/redraw.

.setcpu "65C02"
.segment "CODE"

; === MOS entry points (RTS stubs in emulator) ===
OSWRCH      = $FFEE
OSBYTE      = $FFF4

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

; === Zero page: state ($85-$90) ===
back_buf_idx    = $8A       ; 0 or 1
frame_count     = $8C

; Math workspace
math_a          = $8D       ; multiplier (signed 8-bit)
math_b          = $8E       ; multiplicand (signed 8-bit)
math_res_lo     = $8F       ; result low byte
math_res_hi     = $90       ; result high byte
temp2           = $93       ; general temp / recip value

; Math/recip vars
recip_val       = $9B       ; recip_table[vz] for current vertex
recip_lo_val    = $A4       ; fractional recip correction for current vertex
vz_frac         = $AC       ; per-vertex fractional view Z
recip_shift     = $AD       ; 0, 1, or 2: post-multiply right-shift for extended recip range

; === Opcodes for self-modifying code ===
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

; === Constants ===
SCREEN_W    = 128            ; pixels wide (4bpp, 2 pixels per byte)
SCREEN_H    = 160            ; pixels tall (20 character rows)

; MODE 2 colour 7 (white) pixel masks (4bpp interleaved)
; Left pixel (even x):  bits 5,3,1 = colour 0111 → $2A
; Right pixel (odd x):  bits 4,2,0 = colour 0111 → $15
MASK_LEFT   = $2A
MASK_RIGHT  = $15
MASK_TOGGLE = $3F            ; MASK_LEFT EOR MASK_RIGHT


; =====================================================================
; Entry point ($0800)
; =====================================================================

entry:
    SEI

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
    LDA #$00
    STA CRTC_DAT

    ; Clear both screen buffers ($3000-$7FFF)
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
    CPX #$80
    BNE @clear_page

    ; Initialize state
    LDA #0
    STA back_buf_idx
    STA frame_count

    ; Pre-draw grid on front buffer ($3000) so XOR-erase works
    LDA #$30
    STA screen_page
    JSR draw_grid

    ; Back buffer = buffer 1 ($5800)
    LDA #$58
    STA screen_page
    LDA #1
    STA back_buf_idx

; =====================================================================
; Main loop — per-frame redraw: draw on back, flip, erase from new back
; =====================================================================

main_loop:
    JSR draw_grid           ; XOR-draw 144 lines on back buffer
    JSR wait_vsync
    JSR flip_buffers        ; display it, switch back buffer
    JSR draw_grid           ; XOR-erase from now-back buffer
    JMP main_loop

; =====================================================================
; VSync and buffer flip
; =====================================================================

wait_vsync:
    LDA #0
    STA frame_count
@vs_loop:
    LDA SYS_VIA_IFR
    AND #$02
    BEQ @vs_loop
    LDA #$02
    STA SYS_VIA_IFR
    INC frame_count
    LDA frame_count
    CMP #2
    BCC @vs_loop
    RTS

flip_buffers:
    LDA back_buf_idx
    BNE @show_buf1

    ; Show buffer 0 ($3000): R12=$06
    LDA #12
    STA CRTC_REG
    LDA #$06
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #$00
    STA CRTC_DAT
    LDA #$58
    STA screen_page
    LDA #1
    STA back_buf_idx
    RTS

@show_buf1:
    ; Show buffer 1 ($5800): R12=$0B
    LDA #12
    STA CRTC_REG
    LDA #$0B
    STA CRTC_DAT
    LDA #13
    STA CRTC_REG
    LDA #$00
    STA CRTC_DAT
    LDA #$30
    STA screen_page
    LDA #0
    STA back_buf_idx
    RTS

; =====================================================================
; Draw perspective grid — 18 chains (9 horizontal + 9 vertical)
; =====================================================================

grid_ptr        = $94       ; 2 bytes — pointer into chain data
grid_count      = $96       ; chains remaining
seg_count       = $97       ; segments remaining in current chain
chain_idx       = $98       ; byte offset within current chain

draw_grid:
    LDA #<grid_data
    STA grid_ptr
    LDA #>grid_data
    STA grid_ptr+1
    LDA #18                 ; 9 horizontal + 9 vertical chains
    STA grid_count

@chain_loop:
    ; Load first point of chain
    LDY #0
    LDA (grid_ptr),Y
    STA x0
    INY
    LDA (grid_ptr),Y
    STA y0
    JSR init_base           ; set base, mask_zp, Y for start point
    LDA #2
    STA chain_idx
    LDA #8
    STA seg_count

@seg_loop:
    ; Load next endpoint
    LDY chain_idx
    LDA (grid_ptr),Y
    STA x1
    INY
    LDA (grid_ptr),Y
    STA y1
    INY
    STY chain_idx
    JSR draw_line           ; draw segment, leave state at endpoint
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

    ; Advance to next chain (18 bytes)
    LDA grid_ptr
    CLC
    ADC #18
    STA grid_ptr
    BCC @no_carry
    INC grid_ptr+1
@no_carry:
    DEC grid_count
    BNE @chain_loop
    RTS

; =====================================================================
; Grid chain data — 18 chains × 9 points × 2 bytes = 324 bytes
; Generated by gen_grid.py
; =====================================================================

grid_data:
; Horizontal chains (9 rows × 9 points = 162 bytes)
    .byte   6,109,  21,110,  35,111,  50,119,  64,126,  78,132,  93,134, 107,138, 122,136  ; gz=-4
    .byte  24, 94,  34, 95,  44, 94,  54,101,  64,107,  74,107,  84,105,  94,102, 104,105  ; gz=-3
    .byte  34, 81,  41, 85,  49, 85,  56, 87,  64, 94,  72, 92,  79, 90,  87, 89,  94, 89  ; gz=-2
    .byte  39, 78,  45, 78,  52, 80,  58, 81,  64, 86,  70, 86,  76, 83,  83, 84,  89, 83  ; gz=-1
    .byte  43, 74,  49, 75,  54, 76,  59, 78,  64, 80,  69, 80,  74, 78,  79, 76,  85, 77  ; gz=+0
    .byte  46, 74,  51, 73,  55, 72,  60, 74,  64, 73,  68, 75,  73, 75,  77, 73,  82, 74  ; gz=+1
    .byte  49, 73,  52, 73,  56, 69,  60, 69,  64, 69,  68, 70,  72, 70,  76, 70,  79, 70  ; gz=+2
    .byte  50, 70,  54, 70,  57, 70,  61, 69,  64, 68,  67, 68,  71, 68,  74, 66,  78, 67  ; gz=+3
    .byte  51, 68,  55, 68,  58, 68,  61, 66,  64, 65,  67, 65,  70, 66,  73, 64,  77, 64  ; gz=+4

; Vertical chains (9 columns × 9 points = 162 bytes)
    .byte   6,109,  24, 94,  34, 81,  39, 78,  43, 74,  46, 74,  49, 73,  50, 70,  51, 68  ; gx=-4
    .byte  21,110,  34, 95,  41, 85,  45, 78,  49, 75,  51, 73,  52, 73,  54, 70,  55, 68  ; gx=-3
    .byte  35,111,  44, 94,  49, 85,  52, 80,  54, 76,  55, 72,  56, 69,  57, 70,  58, 68  ; gx=-2
    .byte  50,119,  54,101,  56, 87,  58, 81,  59, 78,  60, 74,  60, 69,  61, 69,  61, 66  ; gx=-1
    .byte  64,126,  64,107,  64, 94,  64, 86,  64, 80,  64, 73,  64, 69,  64, 68,  64, 65  ; gx=+0
    .byte  78,132,  74,107,  72, 92,  70, 86,  69, 80,  68, 75,  68, 70,  67, 68,  67, 65  ; gx=+1
    .byte  93,134,  84,105,  79, 90,  76, 83,  74, 78,  73, 75,  72, 70,  71, 68,  70, 66  ; gx=+2
    .byte 107,138,  94,102,  87, 89,  83, 84,  79, 76,  77, 73,  76, 70,  74, 66,  73, 64  ; gx=+3
    .byte 122,136, 104,105,  94, 89,  89, 83,  85, 77,  82, 74,  79, 70,  78, 67,  77, 64  ; gx=+4

; =====================================================================
; Math routines
; =====================================================================

; ── Unsigned 8x8 → 16-bit multiply ──────────────────────────────────
; Input:  math_a, math_b (unsigned)
; Output: math_res_hi:math_res_lo
; Clobbers: A, X, math_a

umul8x8:
    LDA #0
    STA math_res_hi
    LDX #8
@uml:
    LSR math_a
    BCC @um_no
    CLC
    ADC math_b
@um_no:
    ROR A
    ROR math_res_hi
    DEX
    BNE @uml
    LDX math_res_hi
    STX math_res_lo
    STA math_res_hi
    RTS

; =====================================================================
; Signed 8x8 → 16-bit multiply
; Input:  math_a (signed), math_b (signed)
; Output: math_res_hi:math_res_lo (signed 16-bit)
; =====================================================================

smul8x8:
    PHY                 ; save Y (callers depend on preservation)

    ; Unsigned quarter-square multiply with signed correction
    ; Avoids abs/negate of inputs and conditional 16-bit negate of result

    ; Compute |a - b| first (independent of sum overflow)
    LDA math_a
    SEC
    SBC math_b
    BCS @diff_pos
    EOR #$FF
    INC A               ; 65C02: negate for |diff|
@diff_pos:
    TAY                  ; Y = |a - b|

    ; Compute sum (unsigned)
    LDA math_a
    CLC
    ADC math_b           ; A = (a + b) & $FF
    TAX                  ; X = sum low byte
    BCS @sum_hi          ; sum >= 256, use sqr2 tables

    ; Sum < 256: result = sqr1[sum] - sqr1[|diff|]
    SEC
    LDA sqr_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr_hi,X
    SBC sqr_hi,Y         ; A = unsigned result hi
    BRA @sign_corr

@sum_hi:
    ; Sum >= 256: result = sqr2[sum-256] - sqr1[|diff|]
    SEC
    LDA sqr2_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr2_hi,X
    SBC sqr_hi,Y         ; A = unsigned result hi

@sign_corr:
    ; Signed correction: subtract 256*b if a<0, subtract 256*a if b<0
    ; Carry hi in A throughout, use X for sign tests
    LDX math_a
    BPL @a_pos
    SEC
    SBC math_b
@a_pos:
    LDX math_b
    BPL @done
    SEC
    SBC math_a
@done:
    STA math_res_hi      ; store final result; A also holds it on exit
    PLY                  ; restore Y
    RTS

; recip_lookup: Extended-range reciprocal table lookup
; Input: A = vz_temp (1..127), vz_frac in ZP
; Output: recip_val, recip_lo_val, recip_shift set
; Clobbers: A, X (Y preserved)
recip_lookup:
    CMP #66
    BCS @range2
    CMP #33
    BCS @range1

    ; Range 0: z in [1, 33), direct lookup with full fractional precision
    SEC
    SBC #1
    ASL A
    ASL A
    ASL A
    STA temp2
    LDA vz_frac
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A
    ORA temp2
    TAX
    LDA recip_table,X
    STA recip_val
    LDA recip_lo_table,X
    STA recip_lo_val
    STZ recip_shift
    RTS

@range1:
    ; z in [33, 66), halve z with full K=8 fractional precision, shift=1
    LSR A               ; A = vz_temp/2, carry = vz_temp bit 0
    PHA                 ; save halved integer part
    ; Sub-index = top 3 bits of halved fractional: (carry << 2) | (vz_frac >> 6)
    LDA vz_frac
    ROR A               ; carry (vz_temp[0]) -> bit7, vz_frac[7:1] -> bits 6..0
    LSR A
    LSR A
    LSR A
    LSR A
    LSR A               ; A = (vz_temp[0] << 2) | (vz_frac >> 6) = 0..7
    STA temp2
    PLA
    SEC
    SBC #1
    ASL A
    ASL A
    ASL A
    ORA temp2
    TAX
    LDA recip_table,X
    STA recip_val
    LDA recip_lo_table,X
    STA recip_lo_val
    LDA #1
    STA recip_shift
    RTS

@range2:
    ; z in [66, 128), quarter z with full K=8 fractional precision, shift=2
    ; sub_idx = (vz_temp & 3) * 2 + (vz_frac >> 7) = 0..7
    PHA                 ; save vz_temp
    AND #3              ; A = vz_temp & 3
    ASL A               ; A = (vz_temp & 3) * 2
    STA temp2
    LDA vz_frac
    ASL A               ; carry = vz_frac bit 7
    LDA temp2
    ADC #0              ; A = sub_idx (0..7)
    STA temp2
    PLA                 ; restore vz_temp
    LSR A
    LSR A               ; A = vz_temp / 4
    SEC
    SBC #1
    ASL A
    ASL A
    ASL A
    ORA temp2
    TAX
    LDA recip_table,X
    STA recip_val
    LDA recip_lo_table,X
    STA recip_lo_val
    LDA #2
    STA recip_shift
    RTS

; apply_recip_shift: Arithmetic right-shift math_res by recip_shift
; Clobbers: A, X
apply_recip_shift:
    LDX recip_shift
    BEQ @done
@loop:
    LDA math_res_hi
    CMP #$80            ; carry = sign bit
    ROR math_res_hi
    ROR math_res_lo
    DEX
    BNE @loop
@done:
    RTS

; =====================================================================
; Lookup tables
; =====================================================================

.include "tables.inc"

; =====================================================================
; Line rasterizer (Bresenham) — chainable
;
; Draws from (x0,y0) toward (x1,y1), skipping the last pixel.
; Leaves base, mask_zp, and Y positioned at (x1,y1) for chaining.
; Caller must set up screen state before first call (via init_base).
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

; === SHALLOW pixel loop ===

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

; init_base: Compute screen address for pixel (x0, y0) in MODE 2
; Output: base (2 bytes) = cell address, Y = sub-row, mask_zp = pixel EOR mask
; MODE 2 layout: addr = screen_base + char_row*512 + byte_col*8 + sub_row
;   byte_col = x0 >> 1, char_row = y0 >> 3, sub_row = y0 & 7
init_base:
    ; Pixel mask from x0 bit 0
    LDA x0
    AND #$01
    TAX
    LDA mask_init_table,X
    STA mask_zp

    ; High byte = screen_page + (byte_col >= 32 ? 1 : 0) + char_row * 2
    LDA screen_page
    STA base+1
    LDA x0
    AND #$40            ; bit 6: set if x0 >= 64 (byte_col >= 32)
    BEQ @ib_no_carry
    INC base+1
@ib_no_carry:
    ; Add char_row * 2 to high byte
    LDA y0
    AND #$F8            ; char_row * 8
    LSR A
    LSR A               ; char_row * 2
    CLC
    ADC base+1
    STA base+1

    ; Low byte = (byte_col & 31) * 8 = ((x0 >> 1) << 3) & $FF
    LDA x0
    AND #$FE            ; clear bit 0
    ASL A
    ASL A               ; (x0 & $FE) << 2 = byte_col * 8 (low byte)
    STA base

    ; Y = sub-row
    LDA y0
    AND #$07
    TAY
    RTS
