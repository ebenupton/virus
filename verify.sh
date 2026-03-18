#!/bin/bash
# Build and verify: unique game frames must be a contiguous subsequence of reference.
# Tolerates vsync alignment shifts from code size changes.
set -e
python3 build.py game 2>&1 | tail -1
rm -rf test_frames && mkdir test_frames
./emu game.bin --headless 100 --keys 81 --dump-frames test_frames > /dev/null 2>&1
# Extract unique frame sequence, skip first 2 (init timing varies)
cd test_frames && for f in $(ls *.ppm | sort); do md5 -q $f; done | uniq | tail -n +3 > ../test_unique.txt && cd ..
# Check that every frame in test appears in ref in order (contiguous subsequence)
TEST_N=$(wc -l < test_unique.txt | tr -d ' ')
REF_N=$(wc -l < ref_unique.txt | tr -d ' ')
# Find where test[0] appears in ref
FIRST=$(head -1 test_unique.txt)
OFFSET=$(grep -n "^${FIRST}$" ref_unique.txt | head -1 | cut -d: -f1)
if [ -z "$OFFSET" ]; then
    echo "FAIL: first test frame not found in reference"
    exit 1
fi
# Extract TEST_N lines from ref starting at OFFSET
tail -n +$OFFSET ref_unique.txt | head -n $TEST_N > ref_slice.txt
if diff -q test_unique.txt ref_slice.txt > /dev/null 2>&1; then
    echo "OK: $TEST_N game frames match (offset $((OFFSET-1)) from ref start)"
else
    echo "FAIL: game frames differ"
    diff test_unique.txt ref_slice.txt
    exit 1
fi
wc -c game.bin | awk '{print "Size: " $1 " bytes"}'
