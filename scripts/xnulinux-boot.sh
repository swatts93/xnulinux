#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# In the VM: boot the hosted macOS. Builds fki.ko and xnu.ko against the running kernel (stops on a compile error, never
# boots stale modules), brings up the hosted system's network (xnu0) and GPU bridge (xnudrmd, when there is a render node),
# and loads xnu.ko on the disk mk-macvm-disk.sh made. Returns once XNU is running; xnu.ko stays loaded until the hosted
# system halts or `xnulinux-boot.sh stop` ends it.
#
# Usage: xnulinux-boot.sh            boot it and return once XNU runs
#        xnulinux-boot.sh --wait     boot it and stay until the run ends (systemd: scripts/install-service.sh); the run's
#                                    kernel log goes to /var/log/xnulinux/, the exit status says how it ended
#        xnulinux-boot.sh stop       end it (the disk synced first)
#
# Configuration: /etc/xnulinux.conf, then /var/tmp/mac.conf (written by mk-macvm-disk.sh: ROOT_UUID, BOOT_UUID), then the
# environment:
#   DISK (/var/tmp/mac.img)  RAM_MB (7900)  BOOTARGS  CONSOLE_IN (/var/tmp/console-in)  INPUT_IN (/var/tmp/xnu-input)
#   FB_DUMP (/var/tmp/xnu-fb.raw)  KEYSTORE (/var/tmp/xnu-keystore.bin)  TRUSTCACHE (xnu/trustcache-mac.bin)
#   IMAGE (xnu/kc.bin: the kernel collection under /lib/firmware)  GPU (auto|off)  CPUS (1: the hosted system's CPUs)  XNU_ARGS (more xnu.ko parameters)
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "xnulinux-boot: $*" >&2; exit 1; }
xnu_loaded() { [ -d /sys/module/xnu ]; }	# not `lsmod | grep -q`: with pipefail, grep's early exit can fail the pipe
# the run's insmod: root's only, so another user's process with the same words in its command line cannot hold us
xnu_running() { pgrep -u 0 -f '^insmod xnu-ko/xnu.ko' >/dev/null; }
if [ "${1:-}" = stop ]; then	# end the running hosted system (its disk synced first) and remove xnu.ko
  if ! xnu_loaded; then
    sudo systemctl stop xnudrmd 2>/dev/null || true
    echo "no hosted system is running"; exit 0
  fi
  printf 'sync\n' >> "${CONSOLE_IN:-/var/tmp/console-in}"; sleep 3
  echo 1 | sudo tee /sys/module/xnu/parameters/stop_run >/dev/null
  # every XNU CPU sees the stop at its next host call; one in a long one (disk I/O while the VM shuts down) takes a while
  for _ in $(seq 1 600); do xnu_running || break; sleep 0.2; done
  if xnu_loaded; then sudo rmmod xnu; fi
  sudo systemctl stop xnudrmd 2>/dev/null || true
  echo "hosted system stopped"
  exit
fi
WAIT=0; [ "${1:-}" = --wait ] && WAIT=1
# The configuration is shell code run by a user with sudo: read it only when nobody else can have written it (owned by
# root or by us, not group- or world-writable, not a symlink). /var/tmp is writable by every user.
safe_source() {
  [ -e "$1" ] || return 0
  [ ! -L "$1" ] && [ -f "$1" ] || die "$1: not a regular file; not reading it"
  local owner mode; owner=$(stat -c %u "$1"); mode=$(stat -c %a "$1")
  { [ "$owner" = 0 ] || [ "$owner" = "$(id -u)" ]; } || die "$1: owned by uid $owner, not root or $(id -un); not reading it"
  (( (8#$mode & 8#022) == 0 )) || die "$1: group- or world-writable (mode $mode); not reading it (chmod go-w $1)"
  # shellcheck disable=SC1090
  . "$1"
}
safe_source /etc/xnulinux.conf
safe_source /var/tmp/mac.conf
DISK=${DISK:-/var/tmp/mac.img}; RAM_MB=${RAM_MB:-7900}; GPU=${GPU:-auto}; CPUS=${CPUS:-1}
CONSOLE_IN=${CONSOLE_IN:-/var/tmp/console-in}; INPUT_IN=${INPUT_IN:-/var/tmp/xnu-input}; FB_DUMP=${FB_DUMP:-/var/tmp/xnu-fb.raw}
KEYSTORE=${KEYSTORE:-/var/tmp/xnu-keystore.bin}; TRUSTCACHE=${TRUSTCACHE:-xnu/trustcache-mac.bin}; IMAGE=${IMAGE:-xnu/kc.bin}
BOOTARGS=${BOOTARGS:-amfi_get_out_of_my_way=1 lp-sip0=2050}
: "${ROOT_UUID:?no ROOT_UUID (/var/tmp/mac.conf from mk-macvm-disk.sh)}" "${BOOT_UUID:?no BOOT_UUID}"
xnu_loaded && { echo "xnu.ko is loaded: a hosted system is running (sudo rmmod xnu first)" >&2; exit 1; }

K=/lib/modules/$(uname -r)/build
# What the README requires of the host, checked before anything is built or loaded (XNULINUX_SKIP_PREFLIGHT=1 skips it)
preflight() {
  [ "$(uname -m)" = aarch64 ] || die "the host must be arm64 (this is $(uname -m))"
  [ "$(getconf PAGESIZE)" = 4096 ] || die "the host kernel must use 4 KB pages (it uses $(getconf PAGESIZE) bytes)"
  grep -qw paca /proc/cpuinfo || die "the CPU (or the VM) does not offer pointer authentication (PAC, FEAT_PAuth)"
  local kv; kv=$(uname -r); kv=${kv%%-*}
  printf '6.12\n%s\n' "$kv" | sort -VC || die "fki.ko needs Linux 6.12 or later (this is $(uname -r))"
  [ -d "$K" ] || die "no kernel headers for $(uname -r) in $K (Debian/Ubuntu: sudo apt install linux-headers-$(uname -r))"
  command -v make >/dev/null && command -v python3 >/dev/null || die "make and python3 are needed"
  [ -e "$DISK" ] || die "no system disk $DISK (scripts/mk-macvm-disk.sh)"
}
[ "${XNULINUX_SKIP_PREFLIGHT:-0}" = 1 ] || preflight
build() {	# a module; the end of the build's output on failure (a missing header or tool shows here too)
  local log; log=$(make -s -C "$K" M="$PWD/$1" ${2:-} modules 2>&1) || { echo "$log" | tail -25 >&2; die "building $1 failed"; }
}
build fki-ko
build xnu-ko "KBUILD_EXTRA_SYMBOLS=$PWD/fki-ko/Module.symvers"
# XNU prints a lot (console lines, kprintf): to the ring buffer only (journalctl -k, scripts/vm-dmesg-shell.sh), not the
# VM console, where a CPU printing waits for the console with interrupts off
sudo dmesg -n "${CONLEVEL:-1}"
# fki has the hosted kernel's DRAM from its load at boot (scripts/vm-install-fki-service.sh): reload it only when it changed,
# with the same carve-out
CARVE="carve_base=$(cat /sys/module/fki/parameters/carve_base 2>/dev/null || echo 0x200000000) carve_mb=$(cat /sys/module/fki/parameters/carve_mb 2>/dev/null || echo 8156)"
if [ "$(cat /sys/module/fki/srcversion 2>/dev/null)" != "$(modinfo -F srcversion fki-ko/fki.ko)" ]; then
  sudo systemctl stop xnudrmd 2>/dev/null || true	# it holds fki's /dev/xnu-hostcall
  sudo rmmod fki 2>/dev/null || true
  sudo insmod fki-ko/fki.ko $CARVE ${FKI_ARGS:-}
fi
[ "$(cat /sys/module/fki/parameters/carve_mb 2>/dev/null)" != 0 ] ||
  echo "fki has no carve-out (scripts/vm-install-fki-service.sh): the allocation from CMA may fail" >&2
bash scripts/vm-net-up.sh

# the hosted system's files on the host: console and input queues, the framebuffer xnu.ko writes, the keystore. The
# kernel opens them as root and follows symlinks, and they default to /var/tmp, where any user can create a file first:
# refuse one that is a symlink or someone else's, and keep them private (the console input is a root shell in the hosted
# system, the input queue carries keystrokes, the framebuffer the screen, the keystore its keys).
runtime_file() {
  if [ -L "$1" ] || { [ -e "$1" ] && [ "$(stat -c %u "$1")" != "$(id -u)" ]; }; then
    die "$1 is a symlink or belongs to another user: remove it (sudo rm $1) and start again"
  fi
  ( umask 077; : > "$1" ); chmod 600 "$1"
}
runtime_file "$CONSOLE_IN"; runtime_file "$INPUT_IN"; runtime_file "$FB_DUMP"
# fresh each boot, as the disk was made (persisting it: production.md)
runtime_file "$KEYSTORE"; truncate -s 1M "$KEYSTORE"
# XNU's DRAM is one physically contiguous block (GBs, from CMA): free the page cache and compact first. Right after the VM
# boots the allocation can still fail with the area free (a page in the way not yet migratable): wait and try again,
# for up to three minutes.
# Linux's device interrupts off the CPUs XNU takes (0..CPUS-1): a CPU running XNU's kernel holds Linux's interrupts
# until it next calls the host, so a disk completion routed there waits that long, and with several XNU CPUs one waiting
# for another's I/O can wait for good (as a hypervisor keeps device interrupts off its vCPUs' cores).
NCPU=$(nproc --all)
if [ "$NCPU" -gt "$CPUS" ]; then
  MASK=$(python3 -c "print(format(((1 << $NCPU) - 1) & ~((1 << $CPUS) - 1), 'x'))")
  echo "$MASK" | sudo tee /proc/irq/default_smp_affinity >/dev/null 2>&1 || true
  for f in /proc/irq/*/smp_affinity; do echo "$MASK" | sudo tee "$f" >/dev/null 2>&1 || true; done
fi
# Start xnudrmd BEFORE insmod xnu.ko and wait until it has opened /dev/xnu-hostcall and is serving:
# fast-booting guests (e.g. 16K pages) can open XnuDrm within ~4-5 s of insmod; restarting xnudrmd after
# insmod kills live DRM/Venus clients out from under WindowServer. Never restart xnudrmd while XNU runs.
sudo systemctl stop xnudrmd 2>/dev/null || true
sudo systemctl reset-failed xnudrmd 2>/dev/null || true
if [ "$GPU" != off ] && [ -e /dev/dri/renderD128 ]; then
  make -s -C gpu/xnu-drm >/dev/null
  sudo systemd-run -q --unit xnudrmd --collect "$PWD/gpu/xnu-drm/xnudrmd"
  DRM_READY=0
  DRM_INV=$(systemctl show -p InvocationID --value xnudrmd 2>/dev/null || true)
  for _ in $(seq 1 100); do
    if [ -n "$DRM_INV" ] && sudo journalctl _SYSTEMD_INVOCATION_ID="$DRM_INV" -q --no-pager 2>/dev/null | grep -q "xnudrmd: serving"; then
      DRM_READY=1; break
    fi
    DRM_STATE=$(systemctl show -p ActiveState --value xnudrmd 2>/dev/null || true)
    [ "$DRM_STATE" = active ] || [ "$DRM_STATE" = activating ] || break
    sleep 0.1
  done
  if [ "$DRM_READY" = 1 ]; then
    echo "gpu: xnudrmd ready on /dev/dri/renderD128 (journalctl -u xnudrmd)"
  else
    echo "gpu: xnudrmd did not become ready within 10 s (journalctl -u xnudrmd); continuing with GPU=off" >&2
    sudo systemctl stop xnudrmd 2>/dev/null || true
  fi
fi
# mode=3: the kernel collection; the run lasts until the hosted system halts.
# insmod returns when the run ends: it runs detached, its output in /var/tmp/xnu-insmod.log.
START=$(date +%s)	# the run's log (--wait) starts here, so a failure while xnu.ko loads is in it
runtime_file /var/tmp/xnu-insmod.log
for try in 1 2 3 4 5 6 7 8 9; do
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null
  sudo dmesg -C
  sudo setsid nohup insmod xnu-ko/xnu.ko mode=3 cpus="$CPUS" ram_mb="$RAM_MB" image="$IMAGE" \
    trustcache="$TRUSTCACHE" disk="$DISK" root_uuid="$ROOT_UUID" boot_uuid="$BOOT_UUID" preboot_uuid="$BOOT_UUID" \
    console_in="$CONSOLE_IN" input_in="$INPUT_IN" fb_dump="$FB_DUMP" keystore="$KEYSTORE" bootargs="\"$BOOTARGS\"" ${XNU_ARGS:-} \
    > /var/tmp/xnu-insmod.log 2>&1 < /dev/null &
  sleep 5
  KLOG=$(sudo dmesg)	# read once: `dmesg | grep -q` can fail the pipe (pipefail) when grep stops reading early
  if grep -aqE "fki: carve-out .* (overlaps|is not all RAM)" <<<"$KLOG"; then	# a configuration error: no retry
    grep -aE "fki: carve-out .* (overlaps|is not all RAM)" <<<"$KLOG" >&2
    sudo systemctl stop xnudrmd 2>/dev/null || true
    exit 1
  fi
  grep -aq "contiguous allocation failed" <<<"$KLOG" || break
  if [ $try = 9 ]; then
    echo "no contiguous memory for XNU (CMA: $(grep CmaFree /proc/meminfo))" >&2
    sudo systemctl stop xnudrmd 2>/dev/null || true
    exit 1
  fi
  echo "no contiguous memory for XNU yet: trying again in 20 s"; sleep 20
done
echo "booting: console scripts/xnu-console.sh, screen tools/hosted/fb2png.py $FB_DUMP"
[ $WAIT = 1 ] || exit 0

# --wait: until the run ends (insmod returns), then keep its kernel log and say how it ended: 0 a halt or a stop asked for,
# 2 an XNU panic, 3 the run ended otherwise
collect() {	# the run's kernel log, kept; the status says how it ended
  local LOGDIR=/var/log/xnulinux LOG
  # insmod has returned but xnu.ko stays loaded after a run that ended by itself (a panic, a halt): unload it, or the
  # next start (systemd's restart after a panic) finds it and refuses
  if xnu_loaded; then sudo rmmod xnu || echo "xnu.ko did not unload" >&2; fi
  sudo systemctl stop xnudrmd 2>/dev/null || true
  sudo mkdir -p "$LOGDIR"
  LOG=$LOGDIR/run-$(date -d @"$START" +%Y%m%d-%H%M%S).log
  { cat /var/tmp/xnu-insmod.log; sudo journalctl -k -q -o short-monotonic --no-pager --since @"$START" | grep -a "fki:"; } |
    sudo tee "$LOG" >/dev/null
  ls -1t "$LOGDIR"/run-*.log | tail -n +21 | xargs -r sudo rm -f	# the last 20 runs
  if grep -aq "XNU panic" "$LOG"; then echo "the hosted system panicked: $LOG" >&2; return 2; fi
  if [ "${1:-}" = stopped ] || grep -aq "run stopped by the host" "$LOG"; then echo "the hosted system stopped: $LOG"; return 0; fi
  echo "the run ended: $LOG" >&2; return 3
}
# systemctl stop: ExecStop (xnulinux-boot.sh stop) ends the run, then systemd sends this script SIGTERM
trap 'while xnu_running; do sleep 1; done; collect stopped; exit $?' TERM
while xnu_running; do sleep 2 & wait $!; done
collect; exit $?
