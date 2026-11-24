#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the fki.ko / xnu.ko tests into OUT (default tests/fki/out): fki.ko with a 3 s host-call timeout, xnu.ko,
# hctest.ko, hcsvc (static) and the tiny Mach-O image, next to copies of the test scripts.
#   tests/fki/build.sh [KDIR] [OUT]       KDIR: kernel build tree (default: the running kernel's)
#   cross-build: ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- tests/fki/build.sh /path/to/headers
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); R=$(cd "$D/../.." && pwd)
K=${1:-/lib/modules/$(uname -r)/build}; OUT=${2:-$D/out}
B=$(mktemp -d); trap 'rm -rf "$B"' EXIT
cp -r "$R/fki-ko" "$R/xnu-ko" "$R/xnu-patches" "$B/"; mkdir -p "$B/tests/fki"; cp -r "$D/hctest" "$B/tests/fki/"
M=(make -s -C "$K" ${ARCH:+ARCH=$ARCH} ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE})
"${M[@]}" M="$B/fki-ko" KCFLAGS='-DHC_TIMEOUT=3*HZ' modules
"${M[@]}" M="$B/xnu-ko" KBUILD_EXTRA_SYMBOLS="$B/fki-ko/Module.symvers" modules
"${M[@]}" M="$B/tests/fki/hctest" KBUILD_EXTRA_SYMBOLS="$B/fki-ko/Module.symvers" modules
mkdir -p "$OUT"
"${CROSS_COMPILE:-}gcc" -O2 -Wall -static -pthread -o "$OUT/hcsvc" "$D/hcsvc.c"
python3 "$D/mk-tiny-macho.py" "$OUT/tiny.macho"
cp "$B/fki-ko/fki.ko" "$B/xnu-ko/xnu.ko" "$B/tests/fki/hctest/hctest.ko" "$D/test-hostcall.sh" "$D/test-xnu-load.sh" "$OUT/"
echo "built in $OUT: run (as root, on a test VM) $OUT/test-hostcall.sh and $OUT/test-xnu-load.sh"
