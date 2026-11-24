#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# In the VM (once, after scripts/vm-install-fki-service.sh and with the disk from scripts/mk-macvm-disk.sh): run the hosted
# macOS as a system service. It starts at boot, is stopped cleanly (its disk synced) when the VM shuts down, and is
# started again after a panic or a run that ended by itself; each run's kernel log is in /var/log/xnulinux/.
#   sudo systemctl status xnulinux     journalctl -u xnulinux     settings: /etc/xnulinux.conf (then: systemctl restart xnulinux)
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
U=$(id -un)
[ -f /var/tmp/mac.conf ] || { echo "no /var/tmp/mac.conf: make the disk first (scripts/mk-macvm-disk.sh)" >&2; exit 1; }
[ -f /etc/systemd/system/xnulinux-fki.service ] ||
  { echo "no xnulinux-fki.service: run scripts/vm-install-fki-service.sh first (and reboot)" >&2; exit 1; }
# the service runs as $U and xnulinux-boot.sh uses sudo, with no terminal to ask for a password
sudo -n true 2>/dev/null || { echo "$U needs sudo without a password for the service (the boot script uses sudo)" >&2; exit 1; }
case $P in *[[:space:]]*) echo "the checkout's path has a space ($P): systemd's ExecStart would split it" >&2; exit 1;; esac
[ -f /etc/xnulinux.conf ] || sudo tee /etc/xnulinux.conf >/dev/null <<'CONF'
# The hosted macOS (scripts/xnulinux-boot.sh reads this, then /var/tmp/mac.conf for the disk's UUIDs); the environment
# overrides what is written as ${NAME:-default}
CPUS=${CPUS:-2}		# its CPUs (the Linux CPUs from 0 up; Linux keeps the rest and its device interrupts)
RAM_MB=${RAM_MB:-7900}	# its memory, within fki's carve-out
#DISK=/var/tmp/mac.img
GPU=${GPU:-auto}	# auto: the host GPU when the VM has a render node; off: CPU rendering only
#XNU_ARGS="model=VirtualMac2,1"
#BOOTARGS="amfi_get_out_of_my_way=1 lp-sip0=2050"
CONF
sudo tee /etc/systemd/system/xnulinux.service >/dev/null <<UNIT
[Unit]
Description=xnulinux: the hosted macOS
After=xnulinux-fki.service network-online.target
Wants=network-online.target
Requires=xnulinux-fki.service
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
User=$U
WorkingDirectory=$P
ExecStart=$P/scripts/xnulinux-boot.sh --wait
ExecStop=$P/scripts/xnulinux-boot.sh stop
TimeoutStartSec=infinity
TimeoutStopSec=180
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable xnulinux.service
echo "installed: sudo systemctl start xnulinux (and at every boot); settings in /etc/xnulinux.conf"
