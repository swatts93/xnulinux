#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# In the VM, after fki.ko is loaded: the host side of the hosted macOS's en0. fki.ko's netdev xnu0 carries en0's
# frames; Linux routes and NATs 192.168.77.0/24 out of its own uplink, and dnsmasq (when installed) answers DHCP and
# DNS on xnu0. The hosted system: en0 192.168.77.2/24, router and DNS 192.168.77.1.
set -u
ip link show xnu0 >/dev/null 2>&1 || { echo "vm-net-up: no xnu0 (fki.ko without the link)"; exit 0; }
sudo ip addr replace 192.168.77.1/24 dev xnu0
sudo ip link set xnu0 up
sudo sysctl -q -w net.ipv4.ip_forward=1
up=$(ip route show default | awk '{print $5; exit}')
[ -n "$up" ] || { echo "vm-net-up: no default route: the hosted system gets no NAT to the outside" >&2; exit 0; }
sudo iptables -t nat -C POSTROUTING -s 192.168.77.0/24 -o "$up" -j MASQUERADE 2>/dev/null ||
  sudo iptables -t nat -A POSTROUTING -s 192.168.77.0/24 -o "$up" -j MASQUERADE
# forward only between xnu0 and the uplink, and only replies back in: the hosted system reaches the outside through the
# uplink, nothing outside starts a connection to it
sudo iptables -C FORWARD -i xnu0 -o "$up" -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -i xnu0 -o "$up" -j ACCEPT
sudo iptables -C FORWARD -i "$up" -o xnu0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
  sudo iptables -I FORWARD -i "$up" -o xnu0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
if ! command -v dnsmasq >/dev/null; then
  if command -v apt-get >/dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q dnsmasq-base >/dev/null 2>&1 || true
  else
    echo "vm-net-up: no dnsmasq (install it from your distribution): the hosted system gets no DHCP or DNS" >&2
  fi
fi
if command -v dnsmasq >/dev/null; then
  sudo pkill -f 'dnsmasq.*xnu0' 2>/dev/null
  sudo dnsmasq --interface=xnu0 --bind-interfaces --except-interface=lo --dhcp-range=192.168.77.2,192.168.77.50,12h \
    --dhcp-option=3,192.168.77.1 --dhcp-option=6,192.168.77.1 --pid-file=/run/dnsmasq-xnu0.pid
fi
echo "vm-net-up: xnu0 192.168.77.1/24 up, NAT via $up, dnsmasq: $(command -v dnsmasq >/dev/null && echo yes || echo no)"
