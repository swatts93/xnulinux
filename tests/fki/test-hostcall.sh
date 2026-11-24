#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# fki.ko host-call tests. Root, on a disposable arm64 test VM only: loads and unloads fki.ko. See README.md.
P=$(cd "$(dirname "$0")" && pwd)
NOMAP=${NOMAP:-0}	# a RAM address the device tree marks no-map (fki_phys_peek must not read it); 0 skips the check
FAILS=0
fail() { echo "TEST FAIL $*"; FAILS=$((FAILS + 1)); }
pass() { echo "TEST PASS $*"; }
# run hctest with args; wait for its "done" line; print its lines; check bad=0
hct() {
  name=$1; shift
  dmesg -c >/dev/null
  insmod $P/hctest.ko "$@" || { fail "$name: insmod hctest"; return; }
  i=0; while ! dmesg | grep -q "HCTEST done"; do i=$((i + 1)); [ $i -gt 300 ] && break; sleep 0.1; done
  dmesg | grep -E "HCTEST (done|unit)|HCTEST call [0-9] " | sed 's/^\[[ 0-9.]*\] //'
  if dmesg | grep -q "HCTEST done.* bad=0"; then pass "$name"; else fail "$name"; fi
  rmmod hctest
}
svc_wait() { i=0; while kill -0 $1 2>/dev/null; do i=$((i + 1)); [ $i -gt 100 ] && { kill $1; fail "$2: service still running"; return; }; sleep 0.1; done; wait $1 || fail "$2: service reported failures"; }

echo "kernel $(uname -r)"
insmod $P/fki.ko || { fail "insmod fki.ko"; echo "TESTS-DONE fails=$FAILS"; exit 1; }
[ -c /dev/xnu-hostcall ] && pass "/dev/xnu-hostcall exists ($(ls -l /dev/xnu-hostcall | cut -c1-10))" || fail "/dev/xnu-hostcall missing"
ip link show xnu0 >/dev/null 2>&1 && pass "xnu0 link exists" || fail "no xnu0"

hct "no service: -ENODEV at once; unit checks" calls=2 expect=-19 nomap_pa=$NOMAP

$P/hcsvc echo 50 & S=$!; sleep 0.3
hct "50 round trips of 4000 bytes" calls=50 len=4000; svc_wait $S echo

$P/hcsvc echo 3 & S=$!; sleep 0.3
hct "3 round trips of 1 MiB" calls=3 len=1048576 max=1048576; svc_wait $S echo-1M

$P/hcsvc echo 2 & S=$!; sleep 0.3
hct "zero-length request" calls=2 len=0; svc_wait $S echo-0

$P/hcsvc big 1 8192 & S=$!; sleep 0.3
hct "reply larger than the caller's buffer: -EMSGSIZE" calls=1 len=100 max=4096 expect=-90; svc_wait $S big

$P/hcsvc small 3 & S=$!; sleep 0.3
hct "read too small first: the request survives" calls=3 len=4000; svc_wait $S small

$P/hcsvc dup 5 & S=$!; sleep 0.3
hct "second write to the same call refused" calls=5 len=500; svc_wait $S dup

$P/hcsvc late 1 4500 & S=$!; sleep 0.3
hct "reply after the 3 s timeout: call gets -ETIMEDOUT" calls=1 len=500 expect=-110; svc_wait $S late
$P/hcsvc echo 3 & S=$!; sleep 0.3
hct "channel works again after a timeout" calls=3 len=500; svc_wait $S echo-after-late

$P/hcsvc uffd 2 5000 & S=$!; sleep 0.3
hct "reply copy stalled past the timeout: no stale reply for the next call" calls=2 len=4000; svc_wait $S uffd

$P/hcsvc xlate || fail "xlate checks"
$P/hcsvc nocap || fail "open without CAP_SYS_ADMIN"

dmesg -c >/dev/null
rmmod fki && pass "fki.ko unloads" || fail "rmmod fki"
if dmesg | grep -qE "WARNING|BUG|Oops|Unable to handle"; then dmesg | tail -40; fail "kernel warnings"; else pass "no kernel warnings"; fi
echo "TESTS-DONE fails=$FAILS"
