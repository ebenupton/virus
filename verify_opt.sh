#!/bin/bash
# Build, run headless with Z+K+L, compare first 10 frames to reference
set -e
ca65 --cpu 65C02 -g -DUNROLL_SHALLOW=1 game.s -o game.o 2>/dev/null
ld65 -C linker.cfg game.o -o game.bin 2>/dev/null
rm -f game.o
SIZE=$(wc -c < game.bin | tr -d ' ')
echo "game.bin: $SIZE bytes ($(( 10752 - SIZE )) free)"
rm -rf /tmp/frames_test
mkdir -p /tmp/frames_test
./emu game.bin --headless 100 --keys 81 --dump-frames /tmp/frames_test >/dev/null 2>/dev/null
FAIL=0
for i in $(seq 0 9); do
    REF=$(printf "frames_ref_opt/frame_%06d.ppm" $i)
    TST=$(printf "/tmp/frames_test/frame_%06d.ppm" $i)
    if ! cmp -s "$REF" "$TST"; then
        echo "MISMATCH: frame $i"
        FAIL=1
    fi
done
if [ $FAIL -eq 0 ]; then
    echo "All 10 frames match reference"
fi
