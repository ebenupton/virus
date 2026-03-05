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

.include "raster_zp.inc"

; === Zero page: state ($85-$90) ===
back_buf_idx    = $8A       ; 0 or 1
frame_count     = $8C

lfsr_state      = $9C       ; 8-bit LFSR for random colours

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

; === Constants ===
SCREEN_W    = 128            ; pixels wide (4bpp, 2 pixels per byte)
SCREEN_H    = 160            ; pixels tall (20 character rows)


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

    ; Clear both screen buffers
    LDA #$30
    STA screen_page
    JSR clear_screen
    LDA #$58
    STA screen_page
    JSR clear_screen

    ; Initialize state
    LDA #0
    STA back_buf_idx
    STA frame_count

    ; Seed LFSR for random line colours
    LDA #$A7
    STA lfsr_state

    ; Back buffer = buffer 1 ($5800)
    LDA #$58
    STA screen_page
    LDA #1
    STA back_buf_idx

; =====================================================================
; Main loop — per-frame: clear back buffer, draw, flip
; =====================================================================

main_loop:
    JSR clear_screen        ; clear back buffer (~52K cycles)
    JSR draw_grid           ; draw grid (~65K cycles)
    JSR wait_vsync
    JSR flip_buffers        ; display it, switch back buffer
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
; Clear back buffer — 40 unrolled STZ abs,X (~52K cycles)
; Uses screen_page to select buffer 0 ($3000) or buffer 1 ($5800).
; =====================================================================

clear_screen:
    LDA screen_page
    CMP #$58
    BEQ clear_buf1

clear_buf0:
    LDX #0
@loop:
    STZ $3000,X
    STZ $3100,X
    STZ $3200,X
    STZ $3300,X
    STZ $3400,X
    STZ $3500,X
    STZ $3600,X
    STZ $3700,X
    STZ $3800,X
    STZ $3900,X
    STZ $3A00,X
    STZ $3B00,X
    STZ $3C00,X
    STZ $3D00,X
    STZ $3E00,X
    STZ $3F00,X
    STZ $4000,X
    STZ $4100,X
    STZ $4200,X
    STZ $4300,X
    STZ $4400,X
    STZ $4500,X
    STZ $4600,X
    STZ $4700,X
    STZ $4800,X
    STZ $4900,X
    STZ $4A00,X
    STZ $4B00,X
    STZ $4C00,X
    STZ $4D00,X
    STZ $4E00,X
    STZ $4F00,X
    STZ $5000,X
    STZ $5100,X
    STZ $5200,X
    STZ $5300,X
    STZ $5400,X
    STZ $5500,X
    STZ $5600,X
    STZ $5700,X
    INX
    BNE @loop
    RTS

clear_buf1:
    LDX #0
@loop:
    STZ $5800,X
    STZ $5900,X
    STZ $5A00,X
    STZ $5B00,X
    STZ $5C00,X
    STZ $5D00,X
    STZ $5E00,X
    STZ $5F00,X
    STZ $6000,X
    STZ $6100,X
    STZ $6200,X
    STZ $6300,X
    STZ $6400,X
    STZ $6500,X
    STZ $6600,X
    STZ $6700,X
    STZ $6800,X
    STZ $6900,X
    STZ $6A00,X
    STZ $6B00,X
    STZ $6C00,X
    STZ $6D00,X
    STZ $6E00,X
    STZ $6F00,X
    STZ $7000,X
    STZ $7100,X
    STZ $7200,X
    STZ $7300,X
    STZ $7400,X
    STZ $7500,X
    STZ $7600,X
    STZ $7700,X
    STZ $7800,X
    STZ $7900,X
    STZ $7A00,X
    STZ $7B00,X
    STZ $7C00,X
    STZ $7D00,X
    STZ $7E00,X
    STZ $7F00,X
    INX
    BNE @loop
    RTS

; =====================================================================
; Draw perspective grid — 18 chains (9 horizontal + 9 vertical)
; =====================================================================

grid_ptr        = $94       ; 2 bytes — pointer into chain data
grid_count      = $96       ; chains remaining
seg_count       = $97       ; segments remaining in current chain
chain_idx       = $98       ; byte offset within current chain
saved_y         = $99       ; saved sub-row Y during chain iteration
saved_color     = $9A       ; colour for current chain

draw_grid:
    LDA #<grid_data
    STA grid_ptr
    LDA #>grid_data
    STA grid_ptr+1
    LDA #18
    STA grid_count

@chain_loop:
    ; Pick random colour from LFSR (1-7)
    LSR lfsr_state
    BCC @no_tap
    LDA lfsr_state
    EOR #$B4
    STA lfsr_state
@no_tap:
    LDA lfsr_state
    AND #$07
    BNE @has_color
    LDA #$07                ; avoid black
@has_color:
    TAX
    LDA color_unpack,X
    STA saved_color
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
    ; Save sub-row Y from previous segment / init_base
    STY saved_y
    ; Load next endpoint
    LDY chain_idx
    LDA (grid_ptr),Y
    STA x1
    INY
    LDA (grid_ptr),Y
    STA y1
    INY
    STY chain_idx
    ; Restore sub-row Y before draw_line (it does PHY first thing)
    LDY saved_y
    LDA saved_color
    JSR draw_line           ; draw segment, chaining state
    ; Endpoint becomes start of next segment
    LDA x1
    STA x0
    LDA y1
    STA y0
    DEC seg_count
    BNE @seg_loop

    ; Draw final pixel of chain
    LDA x0
    LSR A                   ; bit 0 → carry
    LDA (base),Y
    BCS @right_final
    AND #$D5
    ORA color_left
    BRA @store_final
@right_final:
    AND #$EA
    ORA color_right
@store_final:
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

; ── Colour unpack table: 3-bit packed → MODE 2 right-pixel (bits 4,2,0) ──
color_unpack:
    .byte $00, $01, $04, $05, $10, $11, $14, $15

; =====================================================================
; Grid chain data — 18 chains × 9 points × 2 bytes = 324 bytes
; Generated by gen_grid.py
; =====================================================================

grid_data:
; Generated by gen_grid.py — 18 chains (9H + 9V), 9 points each
; Camera: height=20.0, pitch=30.0°, focal=128.0
; Grid: spacing=3.0, start=20.0, step=5.0
; Taper ratio: 2.5:1, near width 95% of screen

; Horizontal chains (9 rows × 9 points = 162 bytes)
    .byte   1, 92,  17, 93,  33, 93,  49, 99,  64,103,  79,107,  93,108, 107,111, 122,110  ; gz=-4
    .byte  12, 84,  25, 85,  38, 83,  51, 90,  64, 95,  76, 94,  89, 93, 102, 91, 114, 93  ; gz=-3
    .byte  18, 73,  30, 76,  41, 76,  53, 78,  64, 85,  75, 83,  86, 82,  97, 81, 108, 81  ; gz=-2
    .byte  24, 69,  34, 69,  44, 72,  54, 73,  64, 79,  74, 78,  83, 75,  93, 76, 103, 75  ; gz=-1
    .byte  29, 65,  38, 67,  46, 68,  55, 70,  64, 72,  73, 73,  81, 70,  90, 68,  99, 69  ; gz=+0
    .byte  33, 66,  40, 64,  48, 63,  56, 65,  64, 64,  72, 67,  80, 67,  88, 64,  96, 65  ; gz=+1
    .byte  36, 64,  43, 64,  49, 59,  57, 59,  64, 59,  71, 60,  78, 61,  86, 60,  93, 60  ; gz=+2
    .byte  38, 61,  44, 61,  51, 60,  57, 58,  64, 57,  71, 57,  77, 57,  84, 55,  91, 55  ; gz=+3
    .byte  40, 57,  46, 57,  52, 57,  58, 54,  64, 53,  70, 52,  76, 55,  83, 51,  89, 50  ; gz=+4

; Vertical chains (9 columns × 9 points = 162 bytes)
    .byte   1, 92,  12, 84,  18, 73,  24, 69,  29, 65,  33, 66,  36, 64,  38, 61,  40, 57  ; gx=-4
    .byte  17, 93,  25, 85,  30, 76,  34, 69,  38, 67,  40, 64,  43, 64,  44, 61,  46, 57  ; gx=-3
    .byte  33, 93,  38, 83,  41, 76,  44, 72,  46, 68,  48, 63,  49, 59,  51, 60,  52, 57  ; gx=-2
    .byte  49, 99,  51, 90,  53, 78,  54, 73,  55, 70,  56, 65,  57, 59,  57, 58,  58, 54  ; gx=-1
    .byte  64,103,  64, 95,  64, 85,  64, 79,  64, 72,  64, 64,  64, 59,  64, 57,  64, 53  ; gx=+0
    .byte  79,107,  76, 94,  75, 83,  74, 78,  73, 73,  72, 67,  71, 60,  71, 57,  70, 52  ; gx=+1
    .byte  93,108,  89, 93,  86, 82,  83, 75,  81, 70,  80, 67,  78, 61,  77, 57,  76, 55  ; gx=+2
    .byte 107,111, 102, 91,  97, 81,  93, 76,  90, 68,  88, 64,  86, 60,  84, 55,  83, 51  ; gx=+3
    .byte 122,110, 114, 93, 108, 81, 103, 75,  99, 69,  96, 65,  93, 60,  91, 55,  89, 50  ; gx=+4

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

.include "raster.s"
