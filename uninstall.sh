#!/usr/bin/env bash
# Remove the system-installed Linux_Mint_Wifi_Hotspot app.
set -euo pipefail

PREFIX=/opt/linux-mint-wifi-hotspot
ETC_DIR=/etc/linux-mint-wifi-hotspot
PURGE_DEPS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --purge-deps) PURGE_DEPS=1; shift ;;
    -h|--help)
      echo "Usage: sudo $0 [--prefix /opt/linux-mint-wifi-hotspot] [--purge-deps]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if [[ -x "$PREFIX/bin/wifi-hotspot.sh" ]]; then
  "$PREFIX/bin/wifi-hotspot.sh" stop >/dev/null 2>&1 || true
fi

echo "==> Removing ${PREFIX}"
rm -rf "$PREFIX"
rm -f /usr/local/bin/linux-mint-wifi-hotspot /usr/local/bin/linux-mint-wifi-hotspot-gui
rm -f /usr/local/bin/wifi-hotspot /usr/local/bin/wifi-hotspot-gui
rm -f /usr/share/applications/linux-mint-wifi-hotspot.desktop
rm -f /usr/share/applications/wifi-hotspot.desktop
rm -f /usr/share/polkit-1/actions/com.local.linux-mint-wifi-hotspot.policy
rm -f /usr/share/polkit-1/actions/com.local.wifi-hotspot.policy
rm -f /etc/polkit-1/rules.d/10-linux-mint-wifi-hotspot.rules
rm -f /etc/polkit-1/rules.d/10-wifi-hotspot.rules
rm -f /etc/sudoers.d/linux-mint-wifi-hotspot
rm -f /etc/sudoers.d/wifi-hotspot

if [[ -d "$ETC_DIR" ]]; then
  echo "==> Leaving ${ETC_DIR} (contains your config). Remove manually if desired:"
  echo "    sudo rm -rf ${ETC_DIR}"
fi
if [[ -d /etc/wifi-hotspot ]]; then
  echo "==> Also found old /etc/wifi-hotspot — remove manually if unused:"
  echo "    sudo rm -rf /etc/wifi-hotspot"
fi

if [[ "$PURGE_DEPS" -eq 1 ]]; then
  PKG_LIST="$(dirname "$0")/dependencies/apt-packages.txt"
  if [[ -f "$PKG_LIST" ]]; then
    mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$PKG_LIST")
    echo "==> Purging apt packages: ${PKGS[*]}"
    apt-get remove -y "${PKGS[@]}" || true
  fi
fi

echo "Uninstall complete."
