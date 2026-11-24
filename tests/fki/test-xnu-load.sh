#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# xnu.ko failed-load cleanup tests. Root, on a disposable arm64 test VM only (needs about 300 MB free). See README.md.
P=$(cd "$(dirname "$0")" && pwd); FAILS=0
fail() { echo "TEST FAIL $*"; FAILS=$((FAILS + 1)); }
pass() { echo "TEST PASS $*"; }
free_mb() { awk '/^MemFree/{print int($2/1024)}' /proc/meminfo; }
echo "kernel $(uname -r)"
insmod $P/fki.ko || { echo "TESTS-DONE fails=1"; exit 1; }
mkdir -p /lib/firmware/xnu /mnt/t; cp $P/tiny.macho /lib/firmware/xnu/
mount -t tmpfs tmpfs /mnt/t; dd if=/dev/zero of=/mnt/t/disk.img bs=1M count=4 2>/dev/null; : > /mnt/t/console-in

# 1: files opened before a failure (disk, console input) must be closed again
insmod $P/xnu.ko mode=2 image=xnu/missing disk=/mnt/t/disk.img console_in=/mnt/t/console-in 2>/dev/null
echo "insmod with a missing image: rc=$?"
if umount /mnt/t 2>/dev/null; then pass "failed load closed its files (the tmpfs unmounts)"; else fail "failed load left files open (umount: busy)"; fi

# 2: mode 3, failing after XNU's window is in Linux's kernel table and its contiguous memory taken
dmesg -c >/dev/null
before=$(free_mb)
for i in 1 2 3; do
  insmod $P/xnu.ko mode=3 ram_mb=80 image=xnu/tiny.macho 2>/dev/null; echo "mode 3 attempt $i: rc=$?"
done
after=$(free_mb)
dmesg | grep -E "xnu: (L1 slot|bootstrap window mapped|contiguous DRAM size|threaded)" | sed 's/^\[[ 0-9.]*\] //' | sort | uniq -c
n=$(dmesg | grep -c "bootstrap window mapped")
if dmesg | grep -q "L1 slot already used"; then fail "a failed load left its window in Linux's kernel table (next load: slot in use)"
elif [ "$n" -ge 3 ]; then pass "each failed load removed its window (mapped again $n times; busybox insmod retries a failed load once)"
else fail "mode 3 did not reach the window ($n times)"; fi
echo "MemFree before ${before} MB, after ${after} MB"
if [ $((before - after)) -lt 60 ]; then pass "failed loads gave back their memory (lost $((before - after)) MB)"; else fail "failed loads kept $((before - after)) MB"; fi

dmesg -c >/dev/null
rmmod fki && pass "fki.ko unloads" || fail "rmmod fki"
if dmesg | grep -qE "WARNING|BUG|Oops|Unable to handle"; then dmesg | tail -30; fail "kernel warnings"; else pass "no kernel warnings"; fi
echo "TESTS-DONE fails=$FAILS"
