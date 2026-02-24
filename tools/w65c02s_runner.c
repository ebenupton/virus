/*
 * w65c02s_runner.c -- thin harness around w65c02s.h
 *
 * Loads a flat binary at $0200, sets reset vector to $0200,
 * runs up to 5 000 000 cycles (or until STP), then dumps
 * the full 64 KB memory image to a file or stdout.
 *
 * Usage:  w65c02s_runner <binary> [memdump]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define W65C02S_COARSE 1          /* whole-instruction stepping is fine */
#define W65C02S_IMPL 1
#include "w65c02s.h"

static uint8_t memory[65536];

static uint8_t mem_read(struct w65c02s_cpu *cpu, uint16_t addr)
{
    (void)cpu;
    return memory[addr];
}

static void mem_write(struct w65c02s_cpu *cpu, uint16_t addr, uint8_t val)
{
    (void)cpu;
    memory[addr] = val;
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <binary> [memdump]\n", argv[0]);
        return 1;
    }

    /* Load binary at $0200 */
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    if (size > 0xFE00) {
        fprintf(stderr, "binary too large (%ld bytes)\n", size);
        fclose(f);
        return 1;
    }
    fseek(f, 0, SEEK_SET);
    if ((long)fread(&memory[0x0200], 1, size, f) != size) {
        perror("fread");
        fclose(f);
        return 1;
    }
    fclose(f);

    /* Set reset vector to $0200 */
    memory[0xFFFC] = 0x00;
    memory[0xFFFD] = 0x02;

    /* Allocate and initialise CPU */
    struct w65c02s_cpu *cpu = malloc(w65c02s_cpu_size());
    if (!cpu) { perror("malloc"); return 1; }
    w65c02s_init(cpu, mem_read, mem_write, NULL);

    /* Run up to 5 000 000 cycles */
    unsigned long ran = w65c02s_run_cycles(cpu, 5000000);
    int stopped = w65c02s_is_cpu_stopped(cpu);

    fprintf(stderr, "cycles=%lu stopped=%d\n", ran, stopped);

    /* Copy memory from CPU (writes went through mem_write to memory[]) */
    /* Dump 64 KB */
    const char *dumpfile = (argc > 2) ? argv[2] : NULL;
    if (dumpfile) {
        FILE *out = fopen(dumpfile, "wb");
        if (!out) { perror(dumpfile); free(cpu); return 1; }
        fwrite(memory, 1, 65536, out);
        fclose(out);
    } else {
        /* stdout in binary mode */
        fwrite(memory, 1, 65536, stdout);
    }

    free(cpu);
    return stopped ? 0 : 2;   /* exit 2 if cycle limit hit */
}
