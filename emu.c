/*
 * emu.c -- BBC Micro emulator for Battlezone-style game
 *
 * Uses w65c02s.h (65C02 CPU) + SDL2 (display/keyboard).
 * Loads a flat binary at $0800, sets reset vector to $0800.
 *
 * Video: MODE 2-like, 128x160 (4bpp), 512-byte stripes.
 *   Screen buffers: $3000-$57FF (10K) and $5800-$7FFF (10K).
 *
 * Memory-mapped I/O:
 *   $FE00 write: CRTC register select
 *   $FE01 write: CRTC data (tracks R12/R13 for buffer selection)
 *   $FE43 write: System VIA DDRA (absorbed, no effect)
 *   $FE4D read:  bit 1 = vsync flag; write: clear flagged bits
 *   $FE32 write: Dump call-stack profile to stderr and reset counters
 *   $FE4F read:  System VIA ORA — key scan (bit 7: 0=pressed, 1=not pressed)
 *   $FE4F write: System VIA ORA — latch scan code
 *   $FFEE/$FFF4: RTS stubs (OSWRCH/OSBYTE)
 *
 * Usage:
 *   ./emu game.bin              # interactive SDL window
 *   ./emu game.bin --headless N # run N frames, dump PPM to stdout
 *
 * Build:
 *   cc -O2 -o emu emu.c -Itools $(sdl2-config --cflags --libs)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <limits.h>

#define W65C02S_COARSE 1
#define W65C02S_IMPL 1
#include "w65c02s.h"

/* ── Screen dimensions ───────────────────────────────────────────────── */

#define SCREEN_W 128
#define SCREEN_H 160

/* ── Global state ──────────────────────────────────────────────────────── */

static uint8_t memory[65536];

/* CRTC state */
static uint8_t crtc_reg_select = 0;
static uint8_t crtc_r12 = 0x06;    /* default: screen at $3000 */
static uint8_t crtc_r13 = 0x00;

/* System flags */
static uint8_t vsync_flag = 0;     /* bit 1 = vsync occurred */

/* VIA state */
static uint8_t via_ora = 0;       /* last value written to $FE4F */

/* Cycle counter: write any value to $FE20 to latch current total_cycles,
   read $FE20-$FE23 for 32-bit elapsed cycles since last latch */
static uint64_t cycle_latch = 0;

/* Keyboard state */
static uint8_t key_state = 0;      /* bit0=Z, 1=X, 2=Return, 3=Space, 4=K, 5=M, 6=L */

/* ── Standard MODE 2 palette (logical colour → ARGB) ──────────────── */

static const uint32_t mode2_palette[16] = {
    0xFF000000,  /*  0 = black             */
    0xFFFF0000,  /*  1 = red               */
    0xFF00FF00,  /*  2 = green             */
    0xFFFFFF00,  /*  3 = yellow            */
    0xFF0000FF,  /*  4 = blue              */
    0xFFFF00FF,  /*  5 = magenta           */
    0xFF00FFFF,  /*  6 = cyan              */
    0xFFFFFFFF,  /*  7 = white             */
    0xFF000000,  /*  8 = black  (flash)    */
    0xFFFF0000,  /*  9 = red    (flash)    */
    0xFF00FF00,  /* 10 = green  (flash)    */
    0xFFFFFF00,  /* 11 = yellow (flash)    */
    0xFF0000FF,  /* 12 = blue   (flash)    */
    0xFFFF00FF,  /* 13 = magenta(flash)    */
    0xFF00FFFF,  /* 14 = cyan   (flash)    */
    0xFFFFFFFF,  /* 15 = white  (flash)    */
};

/* ── Profiling ─────────────────────────────────────────────────────── */

#define PROFILE_RANGE_LO 0x0600
#define PROFILE_RANGE_HI 0x3000
#define PROFILE_SIZE     (PROFILE_RANGE_HI - PROFILE_RANGE_LO)

static uint64_t profile_cycles[PROFILE_SIZE];
static int profile_mode = 0;

/* ── Call-stack profiling ──────────────────────────────────────────
 *
 * Instruments JSR ($20) and RTS ($60) to maintain a shadow call stack.
 * This enables "self" vs "inclusive" cycle attribution per function:
 *
 *   self cycles:      time executing the function's own instructions
 *   inclusive cycles:  time in the function + all descendant callees
 *
 * The call stack is an array of JSR target addresses. The entry point
 * ($0800) is pre-loaded as the root. JSR pushes the callee address;
 * RTS pops it. Cycles are attributed BEFORE stack manipulation, so
 * JSR's cycles go to the caller and RTS's cycles go to the callee.
 *
 * Inclusive attribution walks the entire stack for each instruction,
 * adding cycles to every ancestor. This is O(depth) but call depth
 * is typically <20 on 6502, so the overhead is negligible.
 */
#define MAX_CALL_DEPTH 256
static uint16_t call_stack[MAX_CALL_DEPTH];
static int call_depth = 0;
static uint64_t fn_self_cycles[PROFILE_SIZE];
static uint64_t fn_incl_cycles[PROFILE_SIZE];
static int profile_frame_count = 0;

/* Forward declaration */
static void print_call_profile(int num_frames);

/* ── Memory read/write with I/O ────────────────────────────────────── */

static uint8_t mem_read(struct w65c02s_cpu *cpu, uint16_t addr)
{
    switch (addr) {
    case 0xFE20: case 0xFE21: case 0xFE22: case 0xFE23: {
        /* Read 32-bit elapsed cycles since last latch (little-endian) */
        uint32_t elapsed = (uint32_t)(w65c02s_get_cycle_count(cpu) - cycle_latch);
        return (elapsed >> ((addr - 0xFE20) * 8)) & 0xFF;
    }

    case 0xFE4D:
        return vsync_flag;

    case 0xFE4F: {
        uint8_t scan = via_ora & 0x7F;
        int pressed = 0;
        if (scan == 0x61) pressed = (key_state & 0x01);  /* Z */
        if (scan == 0x42) pressed = (key_state & 0x02);  /* X */
        if (scan == 0x49) pressed = (key_state & 0x04);  /* Return */
        if (scan == 0x62) pressed = (key_state & 0x08);  /* Space */
        if (scan == 0x46) pressed = (key_state & 0x10);  /* K */
        if (scan == 0x65) pressed = (key_state & 0x20);  /* M */
        if (scan == 0x56) pressed = (key_state & 0x40);  /* L */
        return pressed ? (via_ora & 0x7F) : (via_ora | 0x80);
    }

    /* OSWRCH stub: RTS ($60) */
    case 0xFFEE:
        return 0x60;

    /* OSBYTE stub: RTS ($60) */
    case 0xFFF4:
        return 0x60;

    default:
        return memory[addr];
    }
}

static void mem_write(struct w65c02s_cpu *cpu, uint16_t addr, uint8_t val)
{
    switch (addr) {
    case 0xFE20:
        /* Latch current cycle count */
        cycle_latch = w65c02s_get_cycle_count(cpu);
        break;
    case 0xFE30:
        /* Debug byte output */
        fprintf(stderr, "%02X", val);
        break;
    case 0xFE31:
        /* Debug newline */
        fprintf(stderr, "\n");
        break;
    case 0xFE32:
        /* Dump call-stack profile and reset counters.
         * First hit just resets (discards init), subsequent hits
         * print one frame's data then reset. */
        if (profile_mode) {
            if (profile_frame_count > 0)
                print_call_profile(profile_frame_count);
            memset(fn_self_cycles, 0, sizeof(fn_self_cycles));
            memset(fn_incl_cycles, 0, sizeof(fn_incl_cycles));
            profile_frame_count = 0;
        }
        break;
    case 0xFE00:
        crtc_reg_select = val;
        break;

    case 0xFE01:
        if (crtc_reg_select == 12)
            crtc_r12 = val;
        else if (crtc_reg_select == 13)
            crtc_r13 = val;
        break;

    case 0xFE43:
        /* DDRA — absorb write */
        break;

    case 0xFE4D:
        /* Clear bits that are set in val */
        vsync_flag &= ~val;
        break;

    case 0xFE4F:
        via_ora = val;
        break;

    default:
        /* RAM: allow writes to $0000-$7FFF (ZP, stack, screen buffers, code) */
        if (addr < 0x8000)
            memory[addr] = val;
        break;
    }
}

/* ── Screen scanout ─────────────────────────────────────────────────── */

/*
 * MODE 2-like screen layout (4bpp, 128x160):
 *   64 byte-columns × 20 character rows, each cell = 8 bytes.
 *   512 bytes per character row ("stripe").
 *
 *   Each byte holds 2 pixels at 4bpp, interleaved:
 *     Pixel 0 (left):  bits 7,5,3,1
 *     Pixel 1 (right): bits 6,4,2,0
 *
 *   For R12=$06: base = $3000
 *   For R12=$0B: base = $5800
 *
 *   Pixel at (x, y):
 *     byte_col  = x / 2
 *     char_row  = y / 8
 *     sub_row   = y & 7
 *     byte_addr = base + char_row*512 + byte_col*8 + sub_row
 *     pixel_pos = x & 1  (0=left, 1=right)
 */

static uint16_t get_screen_base(void)
{
    if (crtc_r12 == 0x0B)
        return 0x5800;
    return 0x3000;
}

/* Extract a 4-bit pixel from a byte */
static inline uint8_t decode_pixel(uint8_t byte, int pos)
{
    if (pos == 0) {
        /* Left pixel: bits 7,5,3,1 → colour bits 3,2,1,0 */
        return ((byte >> 4) & 0x08) |
               ((byte >> 3) & 0x04) |
               ((byte >> 2) & 0x02) |
               ((byte >> 1) & 0x01);
    } else {
        /* Right pixel: bits 6,4,2,0 → colour bits 3,2,1,0 */
        return ((byte >> 3) & 0x08) |
               ((byte >> 2) & 0x04) |
               ((byte >> 1) & 0x02) |
               ( byte       & 0x01);
    }
}

static void scanout_to_argb(uint32_t *pixels, int pitch)
{
    uint16_t base = get_screen_base();

    for (int char_row = 0; char_row < 20; char_row++) {
        for (int byte_col = 0; byte_col < 64; byte_col++) {
            uint16_t cell_addr = base + char_row * 512 + byte_col * 8;
            for (int row = 0; row < 8; row++) {
                uint8_t byte = memory[cell_addr + row];
                int screen_y = char_row * 8 + row;
                int screen_x = byte_col * 2;
                uint8_t left  = decode_pixel(byte, 0);
                uint8_t right = decode_pixel(byte, 1);
                pixels[screen_y * (pitch / 4) + screen_x]     = mode2_palette[left];
                pixels[screen_y * (pitch / 4) + screen_x + 1] = mode2_palette[right];
            }
        }
    }
}

/* ── PPM output ─────────────────────────────────────────────────────── */

static void write_ppm(FILE *f, uint32_t *pixels)
{
    fprintf(f, "P6\n%d %d\n255\n", SCREEN_W, SCREEN_H);
    for (int i = 0; i < SCREEN_W * SCREEN_H; i++) {
        uint32_t c = pixels[i];
        uint8_t r = (c >> 16) & 0xFF;
        uint8_t g = (c >> 8) & 0xFF;
        uint8_t b = c & 0xFF;
        fputc(r, f);
        fputc(g, f);
        fputc(b, f);
    }
}

/* ── Frame dump (2x resolution, direct from BBC Micro VRAM) ────────── */

static void dump_frame_2x(const char *dir, int frame_num)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/frame_%06d.ppm", dir, frame_num);
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return; }

    uint16_t base = get_screen_base();
    fprintf(f, "P6\n%d %d\n255\n", SCREEN_W * 2, SCREEN_H * 2);

    for (int y = 0; y < SCREEN_H; y++) {
        int char_row = y / 8;
        int sub_row = y & 7;
        uint8_t row_buf[SCREEN_W * 2 * 3];
        int p = 0;
        for (int byte_col = 0; byte_col < 64; byte_col++) {
            uint16_t cell_addr = base + char_row * 512 + byte_col * 8;
            uint8_t byte = memory[cell_addr + sub_row];
            for (int px = 0; px < 2; px++) {
                uint8_t col = decode_pixel(byte, px);
                uint32_t argb = mode2_palette[col];
                uint8_t r = (argb >> 16) & 0xFF;
                uint8_t g = (argb >> 8) & 0xFF;
                uint8_t b = argb & 0xFF;
                /* 2x horizontal */
                row_buf[p++] = r; row_buf[p++] = g; row_buf[p++] = b;
                row_buf[p++] = r; row_buf[p++] = g; row_buf[p++] = b;
            }
        }
        /* Write row twice (2x vertical) */
        fwrite(row_buf, 1, sizeof(row_buf), f);
        fwrite(row_buf, 1, sizeof(row_buf), f);
    }
    fclose(f);
}

/* ── Line statistics ───────────────────────────────────────────────── */

/* ZP addresses from raster_zp.inc */
#define ZP_X0 0x80
#define ZP_Y0 0x81
#define ZP_X1 0x82
#define ZP_Y1 0x83

static uint16_t draw_line_addr = 0;  /* set from labels */

struct line_stats {
    unsigned long count;        /* number of lines */
    unsigned long total_pixels; /* total pixels drawn */
};

static struct line_stats ls_horiz = {0, 0};
static struct line_stats ls_vert  = {0, 0};
static struct line_stats ls_other = {0, 0};
static int line_stats_mode = 0;

static void print_line_stats(int num_frames)
{
    unsigned long total = ls_horiz.count + ls_vert.count + ls_other.count;
    fprintf(stderr, "\n=== Line Statistics (%d frames, %lu total calls) ===\n", num_frames, total);
    fprintf(stderr, "%-12s %6s %8s %10s %10s\n", "Type", "Count", "Pixels", "Avg px/ln", "Px/frame");
    if (ls_horiz.count)
        fprintf(stderr, "%-12s %6lu %8lu %10.1f %10.1f\n", "Horizontal",
                ls_horiz.count, ls_horiz.total_pixels,
                (double)ls_horiz.total_pixels / ls_horiz.count,
                (double)ls_horiz.total_pixels / num_frames);
    if (ls_vert.count)
        fprintf(stderr, "%-12s %6lu %8lu %10.1f %10.1f\n", "Vertical",
                ls_vert.count, ls_vert.total_pixels,
                (double)ls_vert.total_pixels / ls_vert.count,
                (double)ls_vert.total_pixels / num_frames);
    fprintf(stderr, "%-12s %6lu %8lu %10.1f %10.1f\n", "Other",
            ls_other.count, ls_other.total_pixels,
            (double)ls_other.total_pixels / ls_other.count,
            (double)ls_other.total_pixels / num_frames);
    fprintf(stderr, "%-12s %6lu %8lu %10s %10.1f\n", "TOTAL",
            total, ls_horiz.total_pixels + ls_vert.total_pixels + ls_other.total_pixels,
            "",
            (double)(ls_horiz.total_pixels + ls_vert.total_pixels + ls_other.total_pixels) / num_frames);

    /* Cycle saving estimates */
    fprintf(stderr, "\n--- Estimated cycle savings ---\n");
    fprintf(stderr, "Horizontal: %.0f pixels/frame × 8 cycles saved = %.0f cycles/frame\n",
            (double)ls_horiz.total_pixels / num_frames,
            (double)ls_horiz.total_pixels / num_frames * 8);
    fprintf(stderr, "Vertical:   %.0f pixels/frame × 12 cycles saved = %.0f cycles/frame\n",
            (double)ls_vert.total_pixels / num_frames,
            (double)ls_vert.total_pixels / num_frames * 12);
    fprintf(stderr, "Total:      %.0f cycles/frame\n",
            (double)ls_horiz.total_pixels / num_frames * 8 +
            (double)ls_vert.total_pixels / num_frames * 12);
}

/* Per-frame cycle tracking */
#define MAX_FRAME_TRACK 100000
static unsigned long frame_active_cycles[MAX_FRAME_TRACK];
static int frame_track_count = 0;

/* Label map for cross-referencing */
#define MAX_LABELS 2048

struct label {
    uint16_t addr;
    char     name[64];
};

static struct label labels[MAX_LABELS];
static int num_labels = 0;

static void load_labels(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f) && num_labels < MAX_LABELS) {
        /* VICE label format: "al 00XXXX .name" */
        unsigned addr;
        char name[64];
        if (sscanf(line, "al %x .%63s", &addr, name) == 2) {
            labels[num_labels].addr = (uint16_t)addr;
            strncpy(labels[num_labels].name, name, 63);
            labels[num_labels].name[63] = '\0';
            num_labels++;
        }
    }
    fclose(f);
}

static const char *find_label(uint16_t addr, int *offset)
{
    /* Find the nearest label at or before addr */
    const char *best = NULL;
    int best_dist = 0x10000;
    for (int i = 0; i < num_labels; i++) {
        int dist = (int)addr - (int)labels[i].addr;
        if (dist >= 0 && dist < best_dist) {
            best_dist = dist;
            best = labels[i].name;
        }
    }
    if (offset) *offset = best_dist;
    return best;
}

static int cmp_profile(const void *a, const void *b)
{
    int ia = *(const int *)a, ib = *(const int *)b;
    if (profile_cycles[ib] > profile_cycles[ia]) return 1;
    if (profile_cycles[ib] < profile_cycles[ia]) return -1;
    return 0;
}

static void print_profile(int num_frames)
{
    /* Compute total cycles in profiled range */
    uint64_t total = 0;
    for (int i = 0; i < PROFILE_SIZE; i++)
        total += profile_cycles[i];

    if (total == 0) {
        fprintf(stderr, "No cycles recorded in $%04X-$%04X\n",
                PROFILE_RANGE_LO, PROFILE_RANGE_HI);
        return;
    }

    /* Sort addresses by cycle count */
    int *indices = malloc(PROFILE_SIZE * sizeof(int));
    for (int i = 0; i < PROFILE_SIZE; i++) indices[i] = i;
    qsort(indices, PROFILE_SIZE, sizeof(int), cmp_profile);

    fprintf(stderr, "\n=== CPU Profile (%d frames, %llu total cycles) ===\n\n",
            num_frames, (unsigned long long)total);

    /* Aggregate by label (routine-level view) */
    fprintf(stderr, "--- Per-routine breakdown ---\n");
    fprintf(stderr, "%-30s %12s %6s\n", "Routine", "Cycles", "%");

    /* Build routine-level totals */
    struct { const char *name; uint64_t cycles; } routines[MAX_LABELS];
    int num_routines = 0;

    for (int i = 0; i < PROFILE_SIZE; i++) {
        if (profile_cycles[i] == 0) continue;
        uint16_t addr = PROFILE_RANGE_LO + i;
        int off;
        const char *lbl = find_label(addr, &off);
        if (!lbl) lbl = "???";

        /* Find or create routine entry */
        int found = -1;
        for (int j = 0; j < num_routines; j++) {
            if (strcmp(routines[j].name, lbl) == 0) { found = j; break; }
        }
        if (found >= 0) {
            routines[found].cycles += profile_cycles[i];
        } else if (num_routines < MAX_LABELS) {
            routines[num_routines].name = lbl;
            routines[num_routines].cycles = profile_cycles[i];
            num_routines++;
        }
    }

    /* Sort routines by cycle count */
    for (int i = 0; i < num_routines - 1; i++)
        for (int j = i + 1; j < num_routines; j++)
            if (routines[j].cycles > routines[i].cycles) {
                const char *tn = routines[i].name;
                uint64_t tc = routines[i].cycles;
                routines[i].name = routines[j].name;
                routines[i].cycles = routines[j].cycles;
                routines[j].name = tn;
                routines[j].cycles = tc;
            }

    for (int i = 0; i < num_routines && i < 30; i++) {
        fprintf(stderr, "%-30s %12llu %5.1f%%\n",
                routines[i].name,
                (unsigned long long)routines[i].cycles,
                100.0 * routines[i].cycles / total);
    }

    /* Top individual addresses */
    fprintf(stderr, "\n--- Top 30 hotspot addresses ---\n");
    fprintf(stderr, "%-6s %-30s %12s %6s\n", "Addr", "Label+offset", "Cycles", "%");

    for (int i = 0; i < 30 && profile_cycles[indices[i]] > 0; i++) {
        uint16_t addr = PROFILE_RANGE_LO + indices[i];
        int off;
        const char *lbl = find_label(addr, &off);
        char labelbuf[80];
        if (lbl) {
            if (off == 0)
                snprintf(labelbuf, sizeof(labelbuf), "%s", lbl);
            else
                snprintf(labelbuf, sizeof(labelbuf), "%s+%d", lbl, off);
        } else {
            labelbuf[0] = '\0';
        }
        fprintf(stderr, "$%04X %-30s %12llu %5.1f%%\n",
                addr, labelbuf,
                (unsigned long long)profile_cycles[indices[i]],
                100.0 * profile_cycles[indices[i]] / total);
    }

    free(indices);

    /* Per-frame cycle summary */
    if (frame_track_count > 0) {
        const unsigned long cpf = 40000; /* 2 MHz / 50 Hz */
        /* Skip first few frames (init) */
        int skip = frame_track_count > 10 ? 5 : 0;
        unsigned long min_c = ULONG_MAX, max_c = 0;
        unsigned long long sum_c = 0;
        int count = 0;
        for (int i = skip; i < frame_track_count; i++) {
            unsigned long c = frame_active_cycles[i];
            if (c < min_c) min_c = c;
            if (c > max_c) max_c = c;
            sum_c += c;
            count++;
        }
        fprintf(stderr, "\n--- Per-frame active cycles (excl. vsync wait) ---\n");
        fprintf(stderr, "Frames: %d (skipped first %d init frames)\n", count, skip);
        fprintf(stderr, "Min:    %lu / %lu (%.1f%%)\n", min_c, cpf,
                100.0 * min_c / cpf);
        fprintf(stderr, "Max:    %lu / %lu (%.1f%%)\n", max_c, cpf,
                100.0 * max_c / cpf);
        fprintf(stderr, "Avg:    %llu / %lu (%.1f%%)\n", sum_c / count, cpf,
                100.0 * sum_c / count / cpf);
        fprintf(stderr, "Budget: %lu cycles/frame @ 2MHz/50Hz\n", cpf);
    }
}

static void print_call_profile(int num_frames)
{
    /* Collect functions with non-zero self or inclusive cycles */
    struct { uint16_t addr; const char *name; uint64_t self; uint64_t incl; } fns[MAX_LABELS];
    int nfns = 0;
    uint64_t total = 0;

    for (int i = 0; i < PROFILE_SIZE; i++) {
        if (fn_self_cycles[i] == 0 && fn_incl_cycles[i] == 0) continue;
        uint16_t addr = PROFILE_RANGE_LO + i;
        /* Only include addresses that are actual labels (JSR targets) */
        const char *name = NULL;
        for (int j = 0; j < num_labels; j++) {
            if (labels[j].addr == addr) { name = labels[j].name; break; }
        }
        if (!name) continue;  /* skip unlabelled addresses */
        fns[nfns].addr = addr;
        fns[nfns].name = name;
        fns[nfns].self = fn_self_cycles[i];
        fns[nfns].incl = fn_incl_cycles[i];
        total += fn_self_cycles[i];
        nfns++;
    }

    /* Sort by inclusive cycles descending */
    for (int i = 0; i < nfns - 1; i++)
        for (int j = i + 1; j < nfns; j++)
            if (fns[j].incl > fns[i].incl) {
                /* swap */
                uint16_t ta = fns[i].addr; const char *tn = fns[i].name;
                uint64_t ts = fns[i].self; uint64_t ti = fns[i].incl;
                fns[i] = fns[j];
                fns[j].addr = ta; fns[j].name = tn;
                fns[j].self = ts; fns[j].incl = ti;
            }

    fprintf(stderr, "\n=== Call-stack profile (%d frames, %llu total cycles) ===\n",
            num_frames, (unsigned long long)total);
    fprintf(stderr, "%-30s %10s %6s %10s %6s\n",
            "Function", "Self", "Self%", "Incl", "Incl%");
    for (int i = 0; i < nfns; i++) {
        fprintf(stderr, "%-30s %10llu %5.1f%% %10llu %5.1f%%\n",
                fns[i].name,
                (unsigned long long)fns[i].self,
                100.0 * fns[i].self / total,
                (unsigned long long)fns[i].incl,
                100.0 * fns[i].incl / total);
    }
}

/* ── Main ───────────────────────────────────────────────────────────── */

#ifndef EMU_HEADLESS_ONLY
#include <SDL.h>
#endif

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <binary> [--headless N] [--profile] [--dump-frames <dir>]\n", argv[0]);
        return 1;
    }

    /* Parse arguments */
    const char *binfile = argv[1];
    int headless = 0;
    int headless_frames = 0;
    int headless_keys = 0;   /* simulated key_state for headless mode */
    int boot_mode = 0;       /* --boot: fill RAM with garbage, load at $3000 */
    int log_mode = 0;        /* dump vertex coords to stderr each frame */
    const char *dump_dir = NULL;  /* if set, dump each scanout frame as 2x PPM */
    uint16_t dump_mem_lo = 0, dump_mem_hi = 0;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--headless") == 0 && i + 1 < argc) {
            headless = 1;
            headless_frames = atoi(argv[++i]);
            if (headless_frames <= 0) headless_frames = 1;
        } else if (strcmp(argv[i], "--keys") == 0 && i + 1 < argc) {
            headless_keys = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--log") == 0) {
            log_mode = 1;
        } else if (strcmp(argv[i], "--profile") == 0) {
            profile_mode = 1;
        } else if (strcmp(argv[i], "--line-stats") == 0) {
            line_stats_mode = 1;
            profile_mode = 1;  /* needs per-instruction stepping */
        } else if (strcmp(argv[i], "--dump-frames") == 0 && i + 1 < argc) {
            dump_dir = argv[++i];
        } else if (strcmp(argv[i], "--dump-mem") == 0 && i + 2 < argc) {
            dump_mem_lo = (uint16_t)strtol(argv[++i], NULL, 0);
            dump_mem_hi = (uint16_t)strtol(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--boot") == 0) {
            boot_mode = 1;
        }
    }

    /* In boot mode, fill all RAM with deterministic garbage before loading */
    if (boot_mode) {
        srand(42);
        for (int i = 0; i < 65536; i++)
            memory[i] = rand() & 0xFF;
    }

    /* Load binary */
    uint16_t load_addr = boot_mode ? 0x3000 : 0x0600;
    long max_size = boot_mode ? 0x5000 : 0x2A00;
    FILE *f = fopen(binfile, "rb");
    if (!f) { perror(binfile); return 1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    if (size > max_size) {
        fprintf(stderr, "binary too large (%ld bytes, max $%04lX)\n", size, max_size);
        fclose(f);
        return 1;
    }
    fseek(f, 0, SEEK_SET);
    if ((long)fread(&memory[load_addr], 1, size, f) != size) {
        perror("fread");
        fclose(f);
        return 1;
    }
    fclose(f);

    /* Put RTS at OSWRCH and OSBYTE stub locations in memory too
     * (in case code JSRs there and the read callback isn't used for fetches) */
    memory[0xFFEE] = 0x60;  /* RTS */
    memory[0xFFF4] = 0x60;  /* RTS */

    /* Set reset vector */
    memory[0xFFFC] = load_addr & 0xFF;
    memory[0xFFFD] = (load_addr >> 8) & 0xFF;

    /* Load label map if available (for profiling) */
    if (profile_mode) {
        char lblpath[256];
        snprintf(lblpath, sizeof(lblpath), "%.*s.labels",
                 (int)(strrchr(binfile, '.') ? strrchr(binfile, '.') - binfile
                                             : strlen(binfile)),
                 binfile);
        load_labels(lblpath);
        fprintf(stderr, "Loaded %d labels from %s\n", num_labels, lblpath);
        memset(profile_cycles, 0, sizeof(profile_cycles));

        /* Find draw_line address for line stats */
        if (line_stats_mode) {
            for (int i = 0; i < num_labels; i++) {
                if (strcmp(labels[i].name, "draw_line") == 0) {
                    draw_line_addr = labels[i].addr;
                    fprintf(stderr, "draw_line at $%04X\n", draw_line_addr);
                    break;
                }
            }
        }
    }

    /* Initialize CPU */
    struct w65c02s_cpu *cpu = malloc(w65c02s_cpu_size());
    if (!cpu) { perror("malloc"); return 1; }
    w65c02s_init(cpu, mem_read, mem_write, NULL);

    /* Cycles per frame: 2 MHz / 50 Hz = 40,000 */
    const unsigned long CYCLES_PER_FRAME = 40000;

    if (headless) {
        /* ── Headless mode ──────────────────────────────────────────── */
        uint32_t *pixels = calloc(SCREEN_W * SCREEN_H, sizeof(uint32_t));
        if (!pixels) { perror("calloc"); free(cpu); return 1; }

        key_state = headless_keys;
        int dump_num = 0;
        /* Initialize call stack for call-stack profiling */
        call_stack[0] = load_addr;
        call_depth = 1;
        memset(fn_self_cycles, 0, sizeof(fn_self_cycles));
        memset(fn_incl_cycles, 0, sizeof(fn_incl_cycles));

        for (int frame = 0; frame < headless_frames; frame++) {
            if (profile_mode) {
                /* Step instruction-by-instruction, recording cycles per PC */
                unsigned long frame_cycles = 0;
                unsigned long frame_vsync_cycles = 0;
                while (frame_cycles < CYCLES_PER_FRAME) {
                    uint16_t pc = w65c02s_reg_get_pc(cpu);
                    uint8_t opcode = memory[pc];
                    uint16_t jsr_target = 0;
                    if (opcode == 0x20)  /* JSR abs */
                        jsr_target = memory[pc + 1] | ((uint16_t)memory[pc + 2] << 8);

                    unsigned long c = w65c02s_step_instruction(cpu);
                    frame_cycles += c;

                    /* Flat per-PC profiling (existing) */
                    if (pc >= PROFILE_RANGE_LO && pc < PROFILE_RANGE_HI)
                        profile_cycles[pc - PROFILE_RANGE_LO] += c;

                    /* Call-stack profiling: self + inclusive attribution */
                    if (call_depth > 0) {
                        uint16_t fn = call_stack[call_depth - 1];
                        if (fn >= PROFILE_RANGE_LO && fn < PROFILE_RANGE_HI)
                            fn_self_cycles[fn - PROFILE_RANGE_LO] += c;
                        for (int d = 0; d < call_depth; d++) {
                            uint16_t afn = call_stack[d];
                            if (afn >= PROFILE_RANGE_LO && afn < PROFILE_RANGE_HI)
                                fn_incl_cycles[afn - PROFILE_RANGE_LO] += c;
                        }
                    }

                    /* Stack manipulation (after attribution) */
                    if (opcode == 0x20 && call_depth < MAX_CALL_DEPTH)
                        call_stack[call_depth++] = jsr_target;
                    else if (opcode == 0x60 && call_depth > 1)
                        call_depth--;

                    /* Line statistics */
                    if (line_stats_mode && draw_line_addr && pc == draw_line_addr) {
                        uint8_t lx0 = memory[ZP_X0], ly0 = memory[ZP_Y0];
                        uint8_t lx1 = memory[ZP_X1], ly1 = memory[ZP_Y1];
                        int dx = (int)lx1 - (int)lx0;
                        int dy = (int)ly1 - (int)ly0;
                        int adx = dx < 0 ? -dx : dx;
                        int ady = dy < 0 ? -dy : dy;
                        int pixels = adx > ady ? adx : ady;
                        if (adx > 50) {
                            fprintf(stderr, "LONG LINE frame=%d: (%d,%d)->(%d,%d) dx=%d dy=%d\n",
                                    frame, lx0, ly0, lx1, ly1, dx, dy);
                        }
                        if (dy == 0 && dx != 0) {
                            ls_horiz.count++;
                            ls_horiz.total_pixels += pixels;
                        } else if (dx == 0 && dy != 0) {
                            ls_vert.count++;
                            ls_vert.total_pixels += pixels;
                        } else if (pixels > 0) {
                            ls_other.count++;
                            ls_other.total_pixels += pixels;
                        }
                    }
                    /* Track vsync wait idle cycles */
                    int off;
                    const char *lbl = find_label(pc, &off);
                    if (lbl && strcmp(lbl, "@vs_loop") == 0)
                        frame_vsync_cycles += c;
                }
                if (frame_track_count < MAX_FRAME_TRACK)
                    frame_active_cycles[frame_track_count++] = frame_cycles - frame_vsync_cycles;
            } else {
                w65c02s_run_cycles(cpu, CYCLES_PER_FRAME);
            }
            vsync_flag |= 0x02;  /* set vsync bit */
            profile_frame_count++;

            if (dump_dir)
                dump_frame_2x(dump_dir, dump_num++);

            if (log_mode) {
                /* Dump state after each frame */
                uint8_t pangle = memory[0x85];
                uint8_t pxlo = memory[0x86], pxhi = memory[0x87];
                uint8_t pzlo = memory[0x88], pzhi = memory[0x89];
                uint8_t back_idx = memory[0x8A];
                uint8_t nlines = back_idx ? memory[0x9E] : memory[0x9D];
                uint16_t lines_base = back_idx ? 0x0328 : 0x0228;
                fprintf(stderr, "F %d angle=%d px=%d.%d pz=%d.%d buf=%d nlines=%d",
                        frame, pangle, pxhi, pxlo, pzhi, pzlo, back_idx, nlines);
                /* Dump lines buffer */
                for (int j = 0; j < nlines && j < 40; j++) {
                    uint16_t addr = lines_base + j * 4;
                    fprintf(stderr, " L%d(%d,%d,%d,%d)", j,
                            memory[addr], memory[addr+1],
                            memory[addr+2], memory[addr+3]);
                }
                /* Dump proj arrays */
                fprintf(stderr, " proj_x=[");
                for (int j = 0; j < 8; j++)
                    fprintf(stderr, "%s%d", j?",":"", memory[0x0200+j]);
                fprintf(stderr, "] proj_x_hi=[");
                for (int j = 0; j < 8; j++)
                    fprintf(stderr, "%s%d", j?",":"", memory[0x0208+j]);
                fprintf(stderr, "] proj_y=[");
                for (int j = 0; j < 8; j++)
                    fprintf(stderr, "%s%d", j?",":"", memory[0x0210+j]);
                fprintf(stderr, "] proj_z=[");
                for (int j = 0; j < 8; j++)
                    fprintf(stderr, "%s%d", j?",":"", memory[0x0218+j]);
                fprintf(stderr, "]\n");
            }
        }

        /* Scanout final frame */
        scanout_to_argb(pixels, SCREEN_W * 4);
        if (!profile_mode)
            write_ppm(stdout, pixels);

        if (profile_mode) {
            print_profile(headless_frames);
            print_call_profile(profile_frame_count);
        }

        if (line_stats_mode)
            print_line_stats(headless_frames);

        /* Dump memory range if requested */
        if (dump_mem_lo < dump_mem_hi) {
            fprintf(stderr, "\n=== Memory dump $%04X-$%04X ===\n", dump_mem_lo, dump_mem_hi);
            for (uint16_t a = dump_mem_lo; a < dump_mem_hi; a += 16) {
                fprintf(stderr, "$%04X:", a);
                for (int j = 0; j < 16 && a + j < dump_mem_hi; j++)
                    fprintf(stderr, " %02X", memory[a + j]);
                fprintf(stderr, "\n");
            }
        }

        free(pixels);
        free(cpu);
        return 0;
    }

#ifndef EMU_HEADLESS_ONLY
    /* ── SDL interactive mode ───────────────────────────────────────── */
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        free(cpu);
        return 1;
    }

    SDL_Window *window = SDL_CreateWindow(
        "BBC Micro - Battlezone",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W * 4, SCREEN_H * 2, 0);
    if (!window) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        free(cpu);
        return 1;
    }

    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!renderer) {
        fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        free(cpu);
        return 1;
    }

    SDL_Texture *texture = SDL_CreateTexture(renderer,
        SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,
        SCREEN_W, SCREEN_H);
    if (!texture) {
        fprintf(stderr, "SDL_CreateTexture failed: %s\n", SDL_GetError());
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        free(cpu);
        return 1;
    }

    /* Initialize call stack for call-stack profiling */
    call_stack[0] = load_addr;
    call_depth = 1;
    memset(fn_self_cycles, 0, sizeof(fn_self_cycles));
    memset(fn_incl_cycles, 0, sizeof(fn_incl_cycles));

    int running = 1;
    int sdl_dump_num = 0;
    while (running) {
        /* Poll keyboard */
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) {
                running = 0;
            }
            if (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE) {
                running = 0;
            }
        }

        /* Read keyboard state */
        const Uint8 *keys = SDL_GetKeyboardState(NULL);
        key_state = 0;
        if (keys[SDL_SCANCODE_Z])      key_state |= 0x01;  /* left */
        if (keys[SDL_SCANCODE_X])      key_state |= 0x02;  /* right */
        if (keys[SDL_SCANCODE_RETURN]) key_state |= 0x04;  /* forward */
        if (keys[SDL_SCANCODE_SPACE])  key_state |= 0x08;  /* back */
        if (keys[SDL_SCANCODE_K])      key_state |= 0x10;  /* pitch up */
        if (keys[SDL_SCANCODE_M])      key_state |= 0x20;  /* pitch down */
        if (keys[SDL_SCANCODE_L])      key_state |= 0x40;  /* thrust */

        /* Run CPU for one frame */
        if (profile_mode) {
            unsigned long frame_cycles = 0;
            while (frame_cycles < CYCLES_PER_FRAME) {
                uint16_t pc = w65c02s_reg_get_pc(cpu);
                uint8_t opcode = memory[pc];
                uint16_t jsr_target = 0;
                if (opcode == 0x20)
                    jsr_target = memory[pc + 1] | ((uint16_t)memory[pc + 2] << 8);

                unsigned long c = w65c02s_step_instruction(cpu);
                frame_cycles += c;

                if (pc >= PROFILE_RANGE_LO && pc < PROFILE_RANGE_HI)
                    profile_cycles[pc - PROFILE_RANGE_LO] += c;

                if (call_depth > 0) {
                    uint16_t fn = call_stack[call_depth - 1];
                    if (fn >= PROFILE_RANGE_LO && fn < PROFILE_RANGE_HI)
                        fn_self_cycles[fn - PROFILE_RANGE_LO] += c;
                    for (int d = 0; d < call_depth; d++) {
                        uint16_t afn = call_stack[d];
                        if (afn >= PROFILE_RANGE_LO && afn < PROFILE_RANGE_HI)
                            fn_incl_cycles[afn - PROFILE_RANGE_LO] += c;
                    }
                }

                if (opcode == 0x20 && call_depth < MAX_CALL_DEPTH)
                    call_stack[call_depth++] = jsr_target;
                else if (opcode == 0x60 && call_depth > 1)
                    call_depth--;
            }
            profile_frame_count++;
        } else {
            w65c02s_run_cycles(cpu, CYCLES_PER_FRAME);
        }

        /* Set vsync flag */
        vsync_flag |= 0x02;

        /* Dump frame if requested */
        if (dump_dir)
            dump_frame_2x(dump_dir, sdl_dump_num++);

        /* Scanout to texture */
        uint32_t *pixels;
        int pitch;
        SDL_LockTexture(texture, NULL, (void **)&pixels, &pitch);
        scanout_to_argb(pixels, pitch);
        SDL_UnlockTexture(texture);

        /* Present */
        SDL_RenderCopy(renderer, texture, NULL, NULL);
        SDL_RenderPresent(renderer);
    }

    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
#endif /* EMU_HEADLESS_ONLY */

    free(cpu);
    return 0;
}
