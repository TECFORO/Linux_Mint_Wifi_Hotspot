#!/usr/bin/env bash
# Install Linux_Mint_Wifi_Hotspot (experimental) on Linux Mint / Ubuntu / Debian (+ NetworkManager).
# Usage:
#   sudo ./install.sh
#   sudo ./install.sh --no-deps
#   sudo ./install.sh --prefix DIR

set -euo pipefail

PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Linux_Mint_Wifi_Hotspot"
PREFIX=/opt/linux-mint-wifi-hotspot
INSTALL_DEPS=1
ETC_DIR=/etc/linux-mint-wifi-hotspot
DEFAULT_PREFIX=/opt/linux-mint-wifi-hotspot

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-deps) INSTALL_DEPS=0; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: sudo $0 [--no-deps] [--prefix ${DEFAULT_PREFIX}]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer needs apt (Debian / Ubuntu / Linux Mint)." >&2
  exit 1
fi

VERSION="$(tr -d '[:space:]' <"$PKG_ROOT/VERSION")"
echo "==> Installing ${APP_NAME} ${VERSION} into ${PREFIX}"
echo "==> EXPERIMENTAL: do not use on a network you cannot afford to disrupt."
echo "    Stop/restore and uninstall.sh are there if something goes wrong."

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  echo "==> Installing apt dependencies from dependencies/apt-packages.txt"
  mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$PKG_ROOT/dependencies/apt-packages.txt")
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y "${PKGS[@]}"
fi

echo "==> Copying application files"
install -d "$PREFIX/bin" "$PREFIX/share" "$PREFIX/docs" "$PREFIX/dependencies" "$ETC_DIR"
install -m 0755 "$PKG_ROOT/src/wifi-hotspot.sh" "$PREFIX/bin/wifi-hotspot.sh"
install -m 0755 "$PKG_ROOT/src/wifi-hotspot-gui.py" "$PREFIX/bin/wifi-hotspot-gui.py"
install -m 0755 "$PKG_ROOT/src/wifi-hotspot-gui" "$PREFIX/bin/wifi-hotspot-gui"
install -m 0644 "$PKG_ROOT/VERSION" "$PREFIX/VERSION"
install -m 0644 "$PKG_ROOT/dependencies/apt-packages.txt" "$PREFIX/dependencies/"
install -m 0644 "$PKG_ROOT/dependencies/versions-known-good.txt" "$PREFIX/dependencies/"
install -m 0644 "$PKG_ROOT/docs/COMPATIBILITY.md" "$PREFIX/docs/"
install -m 0644 "$PKG_ROOT/README.md" "$PREFIX/README.md"
install -m 0644 "$PKG_ROOT/LICENSE" "$PREFIX/LICENSE"

if [[ ! -f "$ETC_DIR/wifi-hotspot.conf" ]]; then
  install -m 0644 "$PKG_ROOT/src/wifi-hotspot.conf.example" "$ETC_DIR/wifi-hotspot.conf"
  echo "==> Created ${ETC_DIR}/wifi-hotspot.conf (edit SSID/password)"
else
  echo "==> Keeping existing ${ETC_DIR}/wifi-hotspot.conf"
fi

echo "==> Installing desktop entry + passwordless PolicyKit / sudoers"
install -d /usr/share/polkit-1/actions /etc/polkit-1/rules.d
install -m 0644 "$PKG_ROOT/packaging/linux-mint-wifi-hotspot.desktop" \
  /usr/share/applications/linux-mint-wifi-hotspot.desktop
install -m 0644 "$PKG_ROOT/packaging/com.local.linux-mint-wifi-hotspot.policy" \
  /usr/share/polkit-1/actions/com.local.linux-mint-wifi-hotspot.policy
install -m 0644 "$PKG_ROOT/packaging/10-linux-mint-wifi-hotspot.rules" \
  /etc/polkit-1/rules.d/10-linux-mint-wifi-hotspot.rules

if [[ "$PREFIX" != "$DEFAULT_PREFIX" ]]; then
  sed -i "s|${DEFAULT_PREFIX}|${PREFIX}|g" \
    /usr/share/polkit-1/actions/com.local.linux-mint-wifi-hotspot.policy
  sed -i "s|${DEFAULT_PREFIX}|${PREFIX}|g" \
    /usr/share/applications/linux-mint-wifi-hotspot.desktop
fi

# Remove old short names from earlier installs if present
rm -f /usr/local/bin/wifi-hotspot /usr/local/bin/wifi-hotspot-gui \
  /usr/share/applications/wifi-hotspot.desktop \
  /usr/share/polkit-1/actions/com.local.wifi-hotspot.policy \
  /etc/polkit-1/rules.d/10-wifi-hotspot.rules \
  /etc/sudoers.d/wifi-hotspot 2>/dev/null || true

ln -sfn "$PREFIX/bin/wifi-hotspot.sh" /usr/local/bin/linux-mint-wifi-hotspot
ln -sfn "$PREFIX/bin/wifi-hotspot-gui" /usr/local/bin/linux-mint-wifi-hotspot-gui

REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
  USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
  UNIT_DIR="${USER_HOME}/.config/systemd/user"
  install -d -o "$REAL_USER" -g "$REAL_USER" "$UNIT_DIR"
  sed -e "s|@PREFIX@|${PREFIX}|g" -e "s|@USER_HOME@|${USER_HOME}|g" \
    "$PKG_ROOT/packaging/linux-mint-wifi-hotspot-restore.service" \
    >"$UNIT_DIR/linux-mint-wifi-hotspot-restore.service"
  chown "$REAL_USER:$REAL_USER" "$UNIT_DIR/linux-mint-wifi-hotspot-restore.service"
  echo "==> Installed user unit (optional: systemctl --user enable --now linux-mint-wifi-hotspot-restore.service)"

  SUDOERS_DST=/etc/sudoers.d/linux-mint-wifi-hotspot
  printf '%s ALL=(root) NOPASSWD: %s/bin/wifi-hotspot.sh\n' "$REAL_USER" "$PREFIX" >"$SUDOERS_DST"
  chmod 0440 "$SUDOERS_DST"
  if ! visudo -cf "$SUDOERS_DST" >/dev/null 2>&1; then
    rm -f "$SUDOERS_DST"
    echo "==> Warning: sudoers syntax check failed; polkit passwordless still applies" >&2
  else
    echo "==> Installed passwordless sudoers for ${REAL_USER}"
  fi
fi

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi

echo
echo "Installed ${APP_NAME} ${VERSION} (experimental)"
echo "  App:     ${PREFIX}"
echo "  Config:  ${ETC_DIR}/wifi-hotspot.conf"
echo "  Menu:    Linux Mint Wifi Hotspot"
echo "  CLI:     linux-mint-wifi-hotspot start|stop|status|restore"
echo "  Undo:    linux-mint-wifi-hotspot stop   OR   sudo ./uninstall.sh"
echo
echo "Next:"
echo "  1) Edit password: sudo nano ${ETC_DIR}/wifi-hotspot.conf"
echo "  2) Open 'Linux Mint Wifi Hotspot' from the menu, or: linux-mint-wifi-hotspot-gui"
echo "  3) After a distro upgrade, read: ${PREFIX}/docs/COMPATIBILITY.md"
echo "  4) If WiFi looks wrong: linux-mint-wifi-hotspot restore"
