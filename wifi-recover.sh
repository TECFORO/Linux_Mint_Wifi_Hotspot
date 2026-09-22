#!/usr/bin/env bash
# Recover WiFi when Realtek rtw89 hangs (SCAN-FAILED / no networks / connection failed)
# without a full reboot. Keeps saved networks and passwords.
#
# Usage: ./wifi-recover.sh

set -euo pipefail

WIFI_IFACE="${WIFI_IFACE:-wlo1}"

if [[ $EUID -ne 0 ]]; then
  if command -v pkexec >/dev/null 2>&1; then
    exec pkexec "$0" "$@"
  fi
  exec sudo -- "$0" "$@"
fi

echo "=== WiFi recover $(date -Iseconds) ==="

# Stop anything that could hold the radio
pkill -f '[h]ostapd' 2>/dev/null || true
pkill -f '[w]ifi-hotspot.sh _watchdog' 2>/dev/null || true
if ip link show ap0 >/dev/null 2>&1; then
  iw dev ap0 del 2>/dev/null || ip link delete ap0 2>/dev/null || true
fi

conn="$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null | head -n1 || true)"
[[ "$conn" == "--" ]] && conn=""

echo "Reloading Realtek rtw89 driver..."
nmcli radio wifi off 2>/dev/null || true
sleep 1
modprobe -r rtw89_8852ae rtw89_8852a rtw89_pci rtw89_core 2>/dev/null || true
sleep 1
modprobe rtw89_8852ae
sleep 2
nmcli radio wifi on
rfkill unblock wifi 2>/dev/null || true
nmcli device set "$WIFI_IFACE" managed yes 2>/dev/null || true
sleep 2

if [[ -n "${conn:-}" ]]; then
  echo "Reconnecting to '${conn}'..."
  nmcli connection up "$conn" ifname "$WIFI_IFACE" 2>/dev/null || true
fi

echo
nmcli -t -f DEVICE,STATE,CONNECTION device status | head -5
nmcli -f SSID,SIGNAL device wifi list 2>/dev/null | head -12 || true
ping -c 1 -W 3 8.8.8.8 2>/dev/null | tail -2 || echo "Ping failed — try selecting a network from the menu."
echo "=== Done (if still dead, reboot once) ==="
