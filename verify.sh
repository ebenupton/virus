#!/bin/bash
# Build, verify 10 frames with X+K+L held, report result
set -e
ca65 --cpu 65C02 game.s -o game.o 2>/dev/null
ld65 -C linker.cfg game.o -o game.bin 2>/dev/null
PASS=1
for n in $(seq 10 19); do
  ./emu game.bin --headless $n --keys 82 --dump dummy 2>/dev/null > /tmp/frame_verify_$n.ppm
  if ! cmp -s /tmp/frame_verify_$n.ppm frames_ref/frame_$n.ppm; then
    echo "FAIL at frame $n"
    PASS=0
  fi
done
if [ $PASS -eq 1 ]; then
  echo "PASS: all 10 frames identical"
fi
wc -c game.bin | awk '{print "Size: " $1 " bytes"}'
