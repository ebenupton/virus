; video.s — Double-buffered video management for BBC Micro MODE 2
;
; Provides: init_screen, clear_screen, wait_vsync, flip_buffers
; Requires: raster_zp.inc (for raster_page)

.include "video_zp.inc"

; ── Hardware registers ──────────────────────────────────────────────
; (also defined in game.s; safe to reference since these are constants)

; =====================================================================
; init_screen — CRTC setup, clear both buffers, init double-buffer state
; =====================================================================

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
    ; A=0 from clear_screen loop
    STA frame_count
    LDA #$58
    JSR set_page
    LDA #1
    STA back_buf_idx
    RTS

; =====================================================================
; wait_vsync — Wait for 2 vertical blanking interrupts
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

; =====================================================================
; flip_buffers — Swap display and back buffers via CRTC
; =====================================================================

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
    LDA #0
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
    LDX #0
    LDA #0
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
