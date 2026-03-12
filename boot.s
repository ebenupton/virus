; boot.s — Bootloader for BBC Micro real hardware
;
; Loads at $3000 via DFS. Sets up CRTC (MODE 2), Video ULA, System VIA,
; copies game code to $0600, zeroes ZP and BSS, then enters the game.
;
; build.py concatenates game.bin after boot_payload to form game_boot.bin.

.setcpu "65C02"
.segment "BOOT"

; Number of pages to copy: CODE segment $0600-$2FFF = $2A00 = 42 pages
CODE_PAGES = $2A

boot_entry:
    SEI
    CLD
    LDX #$FF
    TXS                     ; reset stack

    ; ── CRTC: full MODE 2 setup ──
    LDX #13
@crtc:
    STX $FE00
    LDA crtc_table,X
    STA $FE01
    DEX
    BPL @crtc

    ; ── Video ULA: MODE 2 control ──
    LDA #$F4
    STA $FE20               ; 4bpp, 10MHz pixel rate

    ; ── Video ULA: default MODE 2 palette (identity mapping) ──
    ; Byte = (logical << 4) | (physical XOR 7)
    ; Bits 7-4: palette address, bits 2-0: inverted B/G/R output
    LDX #15
@pal:
    LDA pal_table,X
    STA $FE21
    DEX
    BPL @pal

    ; ── System VIA: keyboard init ──
    LDA #$0F
    STA $FE42               ; DDRB: PB0-3 output (addressable latch)
    LDA #$03
    STA $FE40               ; Stop keyboard auto-scan (manual polling mode)
    LDA #$7F
    STA $FE43               ; DDRA: PA0-6 output, PA7 input
    STA $FE4E               ; IER: disable all VIA interrupts
    STA $FE4D               ; IFR: clear all pending flags

    ; ── Copy game code to $0600 ──
    ; Source: boot_payload (appended after bootloader in memory)
    ; Dest:   $0600
    ; Size:   CODE_PAGES pages (42 × 256 = $2A00 bytes)
    LDA #<boot_payload
    STA $00
    LDA #>boot_payload
    STA $01
    LDA #$00
    STA $02
    LDA #$06
    STA $03
    LDX #CODE_PAGES
    LDY #0
@copy:
    LDA ($00),Y
    STA ($02),Y
    INY
    BNE @copy
    INC $01
    INC $03
    DEX
    BNE @copy

    ; ── Zero ZP ($00-$FF) ──
    ; (Copy loop used ZP pointers $00-$03; zero them now)
    LDA #0
    TAX
@zp:
    STA $00,X
    INX
    BNE @zp

    ; ── Zero $0200-$05FF (4 pages: page 2 + BSS) ──
    ; A=0, X=0, Y=0 at this point (from loops above)
    LDX #4
@bss:
    STA $0200,Y             ; SMC: high byte patched by INC below
    INY
    BNE @bss
    INC @bss+2
    DEX
    BNE @bss

    JMP $0600               ; enter game

; ── CRTC register table (indexed R0..R13) ──
; MODE 2 with R1=64 (128 pixels), R6=20 (160 scanlines), centered
crtc_table:
    ;     R0   R1   R2   R3   R4   R5   R6   R7
    .byte 127, 64,  90,  40,  38,  0,   20,  29
    ;     R8   R9   R10  R11  R12  R13
    .byte 0,   7,   $67, 8,   $06, $00

; ── MODE 2 identity palette: logical colour N → physical colour N (mod 8) ──
; Byte = (N << 4) | ((N & 7) XOR 7), no flash (bit 3 = 0)
pal_table:
    ;     L0    L1    L2    L3    L4    L5    L6    L7
    .byte $07,  $16,  $25,  $34,  $43,  $52,  $61,  $70
    ;     L8    L9    L10   L11   L12   L13   L14   L15
    .byte $87,  $96,  $A5,  $B4,  $C3,  $D2,  $E1,  $F0

boot_payload:
    ; game.bin is concatenated here by build.py
