/*
 * emu.c -- BBC Micro emulator for Battlezone-style game
 *
 * Uses w65c02s.h (65C02 CPU) + SDL2 (display/keyboard).
 * Loads a flat binary at $2000, sets reset vector to $2000.
 *
 * Memory-mapped I/O:
 *   $FE00 write: CRTC register select
 *   $FE01 write: CRTC data (tracks R12/R13 for buffer selection)
 *   $FE43 write: System VIA DDRA (absorbed, no effect)
 *   $FE4D read:  bit 1 = vsync flag; write: clear flagged bits
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

#define W65C02S_COARSE 1
#define W65C02S_IMPL 1
#include "w65c02s.h"

/* ── Global state ──────────────────────────────────────────────────────── */

static uint8_t memory[65536];

/* CRTC state */
static uint8_t crtc_reg_select = 0;
static uint8_t crtc_r12 = 0x08;    /* default: screen at $4000 */
static uint8_t crtc_r13 = 0x00;

/* System flags */
static uint8_t vsync_flag = 0;     /* bit 1 = vsync occurred */

/* VIA state */
static uint8_t via_ora = 0;       /* last value written to $FE4F */

/* Keyboard state */
static uint8_t key_state = 0;      /* bit0=Z, 1=X, 2=Return, 3=Space */

/* ── Memory read/write with I/O ────────────────────────────────────── */

static uint8_t mem_read(struct w65c02s_cpu *cpu, uint16_t addr)
{
    (void)cpu;

    switch (addr) {
    case 0xFE4D:
        return vsync_flag;

    case 0xFE4F: {
        uint8_t scan = via_ora & 0x7F;
        int pressed = 0;
        if (scan == 0x61) pressed = (key_state & 0x01);  /* Z */
        if (scan == 0x42) pressed = (key_state & 0x02);  /* X */
        if (scan == 0x49) pressed = (key_state & 0x04);  /* Return */
        if (scan == 0x62) pressed = (key_state & 0x08);  /* Space */
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
    (void)cpu;

    switch (addr) {
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
 * BBC Micro Mode 4 screen layout (1bpp, 256x256):
 *   Each character cell is 8 pixels wide x 8 rows, stored as 8 contiguous bytes.
 *   32 cells per row = 256 pixels wide, 32 character rows = 256 lines.
 *   Base address determined by CRTC R12:R13.
 *
 *   For R12=$08: base = $4000
 *   For R12=$0C: base = $6000 (actually MA bit 13 set, maps to +$2000)
 *
 *   Pixel at (x, y):
 *     char_col = x / 8
 *     char_row = y / 8
 *     bit_pos  = x & 7  (MSB first: bit 7-x&7)
 *     byte_offset = char_row * 256 + char_col * 8 + (y & 7)
 *     addr = base + byte_offset
 */

static uint16_t get_screen_base(void)
{
    /* R12 holds the high 6 bits of the MA (memory address) start.
     * In BBC Micro, the physical address mapping is:
     *   R12=$08 → $4000, R12=$0C → $6000
     * Simplified: base = (R12 & 0x3F) << 9 | R13, then multiply by 8
     * But for our purposes: R12=$08→$4000, R12=$0C→$6000 */
    if (crtc_r12 == 0x0C)
        return 0x6000;
    return 0x4000;
}

static void scanout_to_argb(uint32_t *pixels, int pitch)
{
    uint16_t base = get_screen_base();

    for (int char_row = 0; char_row < 32; char_row++) {
        for (int char_col = 0; char_col < 32; char_col++) {
            uint16_t cell_addr = base + char_row * 256 + char_col * 8;
            for (int row = 0; row < 8; row++) {
                uint8_t byte = memory[cell_addr + row];
                int screen_y = char_row * 8 + row;
                int screen_x = char_col * 8;
                for (int bit = 7; bit >= 0; bit--) {
                    uint32_t color = (byte & (1 << bit))
                        ? 0xFFFFFFFF   /* white */
                        : 0xFF000000;  /* black */
                    pixels[screen_y * (pitch / 4) + screen_x + (7 - bit)] = color;
                }
            }
        }
    }
}

/* ── PPM output ─────────────────────────────────────────────────────── */

static void write_ppm(FILE *f, uint32_t *pixels)
{
    fprintf(f, "P6\n256 256\n255\n");
    for (int i = 0; i < 256 * 256; i++) {
        uint32_t c = pixels[i];
        uint8_t r = (c >> 16) & 0xFF;
        uint8_t g = (c >> 8) & 0xFF;
        uint8_t b = c & 0xFF;
        fputc(r, f);
        fputc(g, f);
        fputc(b, f);
    }
}

/* ── Profiling ─────────────────────────────────────────────────────── */

#define PROFILE_RANGE_LO 0x1800
#define PROFILE_RANGE_HI 0x8000
#define PROFILE_SIZE     (PROFILE_RANGE_HI - PROFILE_RANGE_LO)

static uint64_t profile_cycles[PROFILE_SIZE];

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
}

/* ── Main ───────────────────────────────────────────────────────────── */

#ifndef EMU_HEADLESS_ONLY
#include <SDL.h>
#endif

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <binary> [--headless N] [--profile]\n", argv[0]);
        return 1;
    }

    /* Parse arguments */
    const char *binfile = argv[1];
    int headless = 0;
    int headless_frames = 0;
    int headless_keys = 0;   /* simulated key_state for headless mode */
    int log_mode = 0;        /* dump vertex coords to stderr each frame */
    int profile_mode = 0;
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
        }
    }

    /* Load binary at $2000 */
    FILE *f = fopen(binfile, "rb");
    if (!f) { perror(binfile); return 1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    if (size > 0x6000) {
        fprintf(stderr, "binary too large (%ld bytes, max $6000)\n", size);
        fclose(f);
        return 1;
    }
    fseek(f, 0, SEEK_SET);
    if ((long)fread(&memory[0x1800], 1, size, f) != size) {
        perror("fread");
        fclose(f);
        return 1;
    }
    fclose(f);

    /* Put RTS at OSWRCH and OSBYTE stub locations in memory too
     * (in case code JSRs there and the read callback isn't used for fetches) */
    memory[0xFFEE] = 0x60;  /* RTS */
    memory[0xFFF4] = 0x60;  /* RTS */

    /* Set reset vector to $1800 */
    memory[0xFFFC] = 0x00;
    memory[0xFFFD] = 0x18;

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
    }

    /* Initialize CPU */
    struct w65c02s_cpu *cpu = malloc(w65c02s_cpu_size());
    if (!cpu) { perror("malloc"); return 1; }
    w65c02s_init(cpu, mem_read, mem_write, NULL);

    /* Cycles per frame: 2 MHz / 50 Hz = 40,000 */
    const unsigned long CYCLES_PER_FRAME = 40000;

    if (headless) {
        /* ── Headless mode ──────────────────────────────────────────── */
        uint32_t *pixels = calloc(256 * 256, sizeof(uint32_t));
        if (!pixels) { perror("calloc"); free(cpu); return 1; }

        key_state = headless_keys;
        for (int frame = 0; frame < headless_frames; frame++) {
            if (profile_mode) {
                /* Step instruction-by-instruction, recording cycles per PC */
                unsigned long frame_cycles = 0;
                while (frame_cycles < CYCLES_PER_FRAME) {
                    uint16_t pc = w65c02s_reg_get_pc(cpu);
                    unsigned long c = w65c02s_step_instruction(cpu);
                    frame_cycles += c;
                    if (pc >= PROFILE_RANGE_LO && pc < PROFILE_RANGE_HI)
                        profile_cycles[pc - PROFILE_RANGE_LO] += c;
                }
            } else {
                w65c02s_run_cycles(cpu, CYCLES_PER_FRAME);
            }
            vsync_flag |= 0x02;  /* set vsync bit */

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
        scanout_to_argb(pixels, 256 * 4);
        if (!profile_mode)
            write_ppm(stdout, pixels);

        if (profile_mode)
            print_profile(headless_frames);

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
        512, 512, 0);
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
        256, 256);
    if (!texture) {
        fprintf(stderr, "SDL_CreateTexture failed: %s\n", SDL_GetError());
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        free(cpu);
        return 1;
    }

    int running = 1;
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
        if (keys[SDL_SCANCODE_SPACE])  key_state |= 0x08;  /* fire */

        /* Run CPU for one frame */
        w65c02s_run_cycles(cpu, CYCLES_PER_FRAME);

        /* Set vsync flag */
        vsync_flag |= 0x02;

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
