#!/usr/bin/env bash
# Temporary WiFi hotspot (installed package).
# Does nothing until Start; on Stop/disconnect restores pre-AP WiFi.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_user_home() {
  local u home
  if [[ -n "${PKEXEC_UID:-}" ]]; then
    u="$(getent passwd "$PKEXEC_UID" | cut -d: -f1 || true)"
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    u="$SUDO_USER"
  elif [[ $EUID -eq 0 ]]; then
    u="$(logname 2>/dev/null || true)"
  else
    u="$(id -un)"
  fi
  if [[ -n "${u:-}" ]]; then
    home="$(getent passwd "$u" | cut -d: -f6 || true)"
  fi
  if [[ -z "${home:-}" || "$home" == "/root" ]]; then
    home="${HOME:-/tmp}"
  fi
  printf '%s\n' "$home"
}

USER_HOME="$(resolve_user_home)"
USER_CONF="${USER_HOME}/.config/linux-mint-wifi-hotspot/wifi-hotspot.conf"

if [[ -f "$USER_CONF" ]]; then
  CONF_FILE="$USER_CONF"
elif [[ -f /etc/linux-mint-wifi-hotspot/wifi-hotspot.conf ]]; then
  CONF_FILE=/etc/linux-mint-wifi-hotspot/wifi-hotspot.conf
elif [[ -f /etc/wifi-hotspot/wifi-hotspot.conf ]]; then
  # Older installs
  CONF_FILE=/etc/wifi-hotspot/wifi-hotspot.conf
elif [[ -f "${SCRIPT_DIR}/wifi-hotspot.conf" ]]; then
  CONF_FILE="${SCRIPT_DIR}/wifi-hotspot.conf"
else
  echo "Missing config" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

if [[ -z "${WIFI_IFACE:-}" ]]; then
  WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
    | awk -F: '$2=="wifi" && $3 ~ /connected/ {print $1; exit}')"
  if [[ -z "$WIFI_IFACE" ]]; then
    WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
      | awk -F: '$2=="wifi"{print $1; exit}')"
  fi
fi

: "${AP_IFACE:=ap0}"
: "${HOTSPOT_CON_NAME:=LinuxMint-Share}"
: "${COUNTRY_CODE:=FR}"
: "${CHECK_INTERVAL:=5}"
: "${FAIL_THRESHOLD:=1}"
: "${STARTUP_VERIFY_TIMEOUT:=30}"
: "${AP_TEARDOWN_SETTLE:=2}"
: "${ENABLE_WATCHDOG:=1}"

if [[ -z "${STATE_DIR:-}" ]]; then
  STATE_DIR="${USER_HOME}/.local/share/linux-mint-wifi-hotspot"
fi
if [[ -z "${LOG_FILE:-}" ]]; then
  LOG_FILE="${STATE_DIR}/hotspot.log"
fi

STATE_FILE="${STATE_DIR}/state.env"
WATCHDOG_PID_FILE="${STATE_DIR}/watchdog.pid"
LOCK_FILE="${STATE_DIR}/lock"
HOSTAPD_CONF="${STATE_DIR}/hostapd.conf"
HOSTAPD_PID="${STATE_DIR}/hostapd.pid"
DNSMASQ_PID="${STATE_DIR}/dnsmasq.pid"
DNSMASQ_LEASES="${STATE_DIR}/dnsmasq.leases"

mkdir -p "$STATE_DIR"
if [[ $EUID -eq 0 ]]; then
  _owner="$(id -un 2>/dev/null || true)"
  if [[ -n "${PKEXEC_UID:-}" ]]; then
    _owner="$(getent passwd "$PKEXEC_UID" | cut -d: -f1)"
  elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    _owner="$SUDO_USER"
  fi
  if [[ -n "${_owner:-}" && "$_owner" != "root" ]]; then
    chown -R "$_owner:$_owner" "$STATE_DIR" 2>/dev/null || true
  fi
fi
unset _owner

needs_root() {
  case "${1:-}" in
    start|stop|restore|restart) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_root() {
  if [[ $EUID -eq 0 ]]; then
    return 0
  fi
  if command -v pkexec >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    exec pkexec env \
      DISPLAY="${DISPLAY:-}" \
      WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
      XAUTHORITY="${XAUTHORITY:-}" \
      DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
      "$0" "$@"
  fi
  exec sudo --preserve-env=DISPLAY,XAUTHORITY,DBUS_SESSION_BUS_ADDRESS -- "$0" "$@"
}

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "$msg" | tee -a "$LOG_FILE"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
  fi
}

clear_state() {
  rm -f "$STATE_FILE" "$WATCHDOG_PID_FILE" "$LOCK_FILE" \
    "$HOSTAPD_CONF" "$HOSTAPD_PID" "$DNSMASQ_PID" "$DNSMASQ_LEASES" \
    "${STATE_DIR}/restore-needed"
}

wifi_is_connected() {
  local state
  state="$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | head -n1 || true)"
  [[ "$state" == "100 (connected)" ]]
}

wifi_radio_on() {
  [[ "$(nmcli radio wifi 2>/dev/null || true)" == "enabled" ]]
}

internet_ok() {
  local gw
  gw="$(ip -4 route show default dev "$WIFI_IFACE" 2>/dev/null | awk '{print $3; exit}')"
  [[ -n "$gw" ]] && wifi_is_connected
}

iwdev_channel() {
  iw dev "$WIFI_IFACE" info 2>/dev/null | awk '/channel/ {print $2; exit}'
}

adapter_supports_concurrent_ap() {
  iw phy 2>/dev/null | grep -A 6 "valid interface combinations" \
    | grep -qE '#\{ *managed *\}|#\{ *AP'
}

hostapd_alive() {
  local pid
  [[ -f "$HOSTAPD_PID" ]] || return 1
  pid="$(cat "$HOSTAPD_PID" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

hotspot_is_active() {
  hostapd_alive && return 0
  ip link show "$AP_IFACE" >/dev/null 2>&1
}

check_password() {
  if [[ -z "${HOTSPOT_PASSWORD:-}" || "$HOTSPOT_PASSWORD" == "ChangeMe-Use-A-Strong-Password" ]]; then
    echo "Set HOTSPOT_PASSWORD in ${CONF_FILE} before starting." >&2
    exit 1
  fi
  if ((${#HOTSPOT_PASSWORD} < 8)); then
    echo "HOTSPOT_PASSWORD must be at least 8 characters." >&2
    exit 1
  fi
}

uplink_dns_servers() {
  local dns
  dns="$(nmcli -g IP4.DNS device show "$WIFI_IFACE" 2>/dev/null | tr '|' ' ' | tr '\n' ' ')"
  dns="$(echo "$dns" | xargs || true)"
  [[ -n "$dns" ]] || dns="1.1.1.1 8.8.8.8"
  printf '%s\n' "$dns"
}

# Snapshot WiFi-as-it-was BEFORE the AP touches anything.
snapshot_pre_ap_wifi() {
  local conn channel radio managed ipf
  conn="$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null | head -n1 || true)"
  if [[ -z "$conn" || "$conn" == "--" ]]; then
    log "ERROR: No active WiFi connection to snapshot."
    return 1
  fi
  channel="$(iwdev_channel)"
  radio="$(nmcli radio wifi 2>/dev/null || echo enabled)"
  managed="$(nmcli -g GENERAL.NM-MANAGED device show "$WIFI_IFACE" 2>/dev/null | head -n1 || echo yes)"
  ipf="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  cat >"$STATE_FILE" <<EOF
HOTSPOT_MODE='temporary'
SAVED_CONNECTION='${conn//\'/\'\\\'\'}'
SAVED_DEVICE='${WIFI_IFACE}'
SAVED_CHANNEL='${channel}'
SAVED_WIFI_RADIO='${radio}'
SAVED_WIFI_MANAGED='${managed}'
HOTSPOT_ACTIVE=1
AP_IFACE='${AP_IFACE}'
HOTSPOT_SSID='${HOTSPOT_SSID}'
STARTED_AT='$(date -Iseconds)'
IP_FORWARD_WAS='${ipf}'
EOF
  log "Snapshot before AP: connection='${conn}' channel='${channel}' radio='${radio}' managed='${managed}'"
}

purge_nm_ap_profiles() {
  local name uuid mode
  while IFS=: read -r name uuid; do
    [[ -n "$uuid" ]] || continue
    mode="$(nmcli -g 802-11-wireless.mode connection show "$uuid" 2>/dev/null || true)"
    if [[ "$mode" == "ap" ]]; then
      nmcli connection down "$uuid" >/dev/null 2>&1 || true
      nmcli connection delete "$uuid" >/dev/null 2>&1 && log "Removed NM AP profile '${name}'" || true
    fi
  done < <(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null | awk -F: '$3 ~ /wireless|802-11/ {print $1":"$2}')
  for legacy in "$HOTSPOT_CON_NAME" Hotspot Hotspot-1; do
    if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$legacy"; then
      nmcli connection down "$legacy" >/dev/null 2>&1 || true
      nmcli connection delete "$legacy" >/dev/null 2>&1 || true
      log "Removed leftover profile '${legacy}'"
    fi
  done
}

stop_watchdog() {
  if [[ -f "$WATCHDOG_PID_FILE" ]]; then
    local pid
    pid="$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      log "Stopped watchdog (pid ${pid})"
    fi
    rm -f "$WATCHDOG_PID_FILE"
  fi
  pkill -f '[w]ifi-hotspot\.sh _watchdog' 2>/dev/null || true
}

teardown_ap() {
  log "Tearing down temporary AP..."

  if [[ -f "$HOSTAPD_PID" ]]; then
    local pid
    pid="$(cat "$HOSTAPD_PID" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 0.4
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$HOSTAPD_PID"
  fi
  pkill -f "hostapd ${HOSTAPD_CONF}" 2>/dev/null || true

  if [[ -f "$DNSMASQ_PID" ]]; then
    local pid
    pid="$(cat "$DNSMASQ_PID" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$DNSMASQ_PID"
  fi
  pkill -f "dnsmasq.*${DNSMASQ_LEASES}" 2>/dev/null || true

  iptables -t nat -D POSTROUTING -o "$WIFI_IFACE" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$AP_IFACE" -o "$WIFI_IFACE" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$WIFI_IFACE" -o "$AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -i "$AP_IFACE" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$AP_IFACE" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "$AP_IFACE" -j ACCEPT 2>/dev/null || true

  if command -v ufw >/dev/null 2>&1; then
    ufw --force delete allow in on "$AP_IFACE" >/dev/null 2>&1 || true
    ufw route delete allow in on "$AP_IFACE" out on "$WIFI_IFACE" >/dev/null 2>&1 || true
    ufw route delete allow in on "$WIFI_IFACE" out on "$AP_IFACE" >/dev/null 2>&1 || true
  fi

  if ip link show "$AP_IFACE" >/dev/null 2>&1; then
    ip link set "$AP_IFACE" down 2>/dev/null || true
    iw dev "$AP_IFACE" del 2>/dev/null || true
    ip link delete "$AP_IFACE" 2>/dev/null || true
    log "Removed ${AP_IFACE}"
  fi

  rm -f "$HOSTAPD_CONF" "$DNSMASQ_LEASES"
}

restore_pre_ap_wifi() {
  # Restore exactly what we snapshotted before start.
  local conn="${SAVED_CONNECTION:-}"
  local radio="${SAVED_WIFI_RADIO:-enabled}"
  local managed="${SAVED_WIFI_MANAGED:-yes}"

  nmcli device set "$WIFI_IFACE" managed yes >/dev/null 2>&1 || true

  if [[ "$radio" == "enabled" ]]; then
    nmcli radio wifi on >/dev/null 2>&1 || true
  fi
  # If radio was disabled before start, leave it disabled after stop.
  if [[ "$radio" == "disabled" ]]; then
    nmcli radio wifi off >/dev/null 2>&1 || true
    log "Restored WiFi radio to disabled (as before AP)."
    return 0
  fi

  sleep "${AP_TEARDOWN_SETTLE}"

  if [[ -n "$conn" ]]; then
    if wifi_is_connected; then
      local now
      now="$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null | head -n1 || true)"
      if [[ "$now" == "$conn" ]]; then
        log "WiFi already back on '${conn}'."
        return 0
      fi
    fi
    log "Restoring WiFi connection '${conn}'..."
    if nmcli connection up "$conn" ifname "$WIFI_IFACE" >/dev/null 2>&1; then
      log "Pre-AP WiFi connection restored."
    else
      log "WARNING: Could not bring up '${conn}'. WiFi path is clear — join from the menu."
    fi
  fi
}

# Public restore: stop AP + restore snapshot (or just purge if no snapshot).
restore_network() {
  local reason="${1:-manual restore}"

  if [[ ! -f "$STATE_FILE" ]] && ! hotspot_is_active; then
    purge_nm_ap_profiles
    nmcli device set "$WIFI_IFACE" managed yes >/dev/null 2>&1 || true
    echo "Nothing to restore (no temporary AP was active)."
    return 0
  fi

  log "Stopping temporary AP and restoring pre-AP WiFi (${reason})..."
  stop_watchdog
  load_state
  teardown_ap
  purge_nm_ap_profiles

  if [[ -n "${IP_FORWARD_WAS:-}" ]]; then
    sysctl -w "net.ipv4.ip_forward=${IP_FORWARD_WAS}" >/dev/null 2>&1 || true
  fi

  restore_pre_ap_wifi
  clear_state
  log "Restore complete — system WiFi is back to pre-AP state."
}

watchdog_loop() {
  local wifi_failures=0
  local lock="${STATE_DIR}/watchdog.lock"
  local interval="${CHECK_INTERVAL}"
  local threshold="${FAIL_THRESHOLD}"

  # Temporary AP always watches — if WiFi dies, AP dies immediately.
  exec 9>"$lock"
  if ! flock -n 9; then
    exit 0
  fi
  echo $$ >"$WATCHDOG_PID_FILE"
  log "Watchdog started (pid $$): AP dies the moment WiFi disconnects."

  while [[ -f "$STATE_FILE" ]]; do
    if ! hostapd_alive; then
      log "Watchdog: hostapd gone — restoring pre-AP WiFi."
      [[ $EUID -eq 0 ]] && restore_network "hostapd died"
      exit 1
    fi

    if ! wifi_radio_on; then
      log "Watchdog: WiFi radio off — shutting AP and restoring."
      [[ $EUID -eq 0 ]] && restore_network "WiFi radio disabled"
      exit 1
    fi

    if wifi_is_connected; then
      wifi_failures=0
    else
      wifi_failures=$((wifi_failures + 1))
      log "Watchdog: WiFi disconnected (${wifi_failures}/${threshold})"
      if ((wifi_failures >= threshold)); then
        [[ $EUID -eq 0 ]] && restore_network "WiFi disconnected"
        exit 1
      fi
    fi
    sleep "$interval"
  done
}

start_watchdog() {
  stop_watchdog
  nohup "$0" _watchdog >>"$LOG_FILE" 2>&1 &
  echo $! >"$WATCHDOG_PID_FILE"
  disown $! 2>/dev/null || true
  log "Watchdog running (pid $(cat "$WATCHDOG_PID_FILE"))."
}

write_hostapd_conf() {
  local channel="$1"
  cat >"$HOSTAPD_CONF" <<EOF
interface=${AP_IFACE}
driver=nl80211
ssid=${HOTSPOT_SSID}
country_code=${COUNTRY_CODE:-FR}
ieee80211d=1
hw_mode=g
channel=${channel}
ieee80211n=0
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
ieee80211w=0
wpa=2
wpa_passphrase=${HOTSPOT_PASSWORD}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
beacon_int=100
logger_syslog=-1
logger_stdout=-1
logger_stdout_level=2
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
EOF
}

create_ap_iface() {
  local phy mac base b1
  phy="$(iw dev "$WIFI_IFACE" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}')"
  [[ -n "$phy" ]] || phy="phy0"

  if ip link show "$AP_IFACE" >/dev/null 2>&1; then
    iw dev "$AP_IFACE" del 2>/dev/null || ip link delete "$AP_IFACE" 2>/dev/null || true
    sleep 0.4
  fi

  log "Creating ${AP_IFACE} on ${phy}..."
  iw phy "$phy" interface add "$AP_IFACE" type __ap || return 1

  base="$(cat "/sys/class/net/${WIFI_IFACE}/address" 2>/dev/null || echo "50:c2:e8:e3:e2:73")"
  b1="$(printf '%02x' $(( (0x${base:0:2} | 0x02) & 0xfe )))"
  mac="${b1}${base:2}"
  ip link set "$AP_IFACE" address "$mac" || true
  nmcli device set "$AP_IFACE" managed no >/dev/null 2>&1 || true
  ip link set "$AP_IFACE" up
  ip addr flush dev "$AP_IFACE" 2>/dev/null || true
  ip addr add "${AP_GATEWAY}/24" dev "$AP_IFACE"
}

start_hotspot() {
  if [[ -f "$LOCK_FILE" ]]; then
    echo "Hotspot operation already in progress." >&2
    exit 1
  fi
  if hotspot_is_active && [[ -f "$STATE_FILE" ]]; then
    echo "Temporary hotspot already running. Stop it first." >&2
    exit 1
  fi

  check_password

  if ! wifi_is_connected || ! internet_ok; then
    echo "Connect to WiFi first. This temporary hotspot only shares an existing connection." >&2
    exit 1
  fi

  if ! adapter_supports_concurrent_ap; then
    echo "This adapter does not support sharing WiFi while staying connected." >&2
    exit 1
  fi

  local channel
  channel="$(iwdev_channel)"
  if [[ -z "$channel" ]]; then
    echo "Could not read WiFi channel." >&2
    exit 1
  fi

  touch "$LOCK_FILE"
  trap 'restore_network "interrupted during startup"; rm -f "$LOCK_FILE"; exit 130' INT TERM

  # Clean any old blockers, then snapshot, then start.
  purge_nm_ap_profiles
  snapshot_pre_ap_wifi || { rm -f "$LOCK_FILE"; trap - INT TERM; exit 1; }

  log "Starting temporary hotspot SSID='${HOTSPOT_SSID}' on ${AP_IFACE} (channel ${channel})..."

  if ! create_ap_iface; then
    restore_network "failed to create AP interface"
    rm -f "$LOCK_FILE"; trap - INT TERM; exit 1
  fi

  sleep 1
  if ! wifi_is_connected || ! internet_ok; then
    restore_network "AP iface broke uplink"
    rm -f "$LOCK_FILE"; trap - INT TERM; exit 1
  fi

  write_hostapd_conf "$channel"
  if ! hostapd -B -P "$HOSTAPD_PID" "$HOSTAPD_CONF" >>"$LOG_FILE" 2>&1; then
    restore_network "hostapd failed"
    rm -f "$LOCK_FILE"; trap - INT TERM; exit 1
  fi

  sleep 1
  if ! wifi_is_connected || ! internet_ok; then
    restore_network "hostapd broke uplink"
    rm -f "$LOCK_FILE"; trap - INT TERM; exit 1
  fi

  local dns_list dns_opt s
  dns_list="$(uplink_dns_servers)"
  dns_opt=""
  for s in $dns_list; do dns_opt="${dns_opt}${dns_opt:+,}${s}"; done

  if ! dnsmasq \
      --conf-file=/dev/null \
      --interface="$AP_IFACE" \
      --bind-interfaces \
      --except-interface=lo \
      --listen-address="$AP_GATEWAY" \
      --port=0 \
      --dhcp-range="${AP_DHCP_START},${AP_DHCP_END},12h" \
      --dhcp-option=3,"$AP_GATEWAY" \
      --dhcp-option=6,"$dns_opt" \
      --dhcp-authoritative \
      --pid-file="$DNSMASQ_PID" \
      --dhcp-leasefile="$DNSMASQ_LEASES" \
      --log-facility=- \
      >>"$LOG_FILE" 2>&1; then
    restore_network "dnsmasq failed"
    rm -f "$LOCK_FILE"; trap - INT TERM; exit 1
  fi

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -o "$WIFI_IFACE" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$WIFI_IFACE" -j MASQUERADE
  iptables -C FORWARD -i "$AP_IFACE" -o "$WIFI_IFACE" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$AP_IFACE" -o "$WIFI_IFACE" -j ACCEPT
  iptables -C FORWARD -i "$WIFI_IFACE" -o "$AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$WIFI_IFACE" -o "$AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -C INPUT -i "$AP_IFACE" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT 1 -i "$AP_IFACE" -j ACCEPT
  iptables -C FORWARD -i "$AP_IFACE" -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -i "$AP_IFACE" -j ACCEPT
  iptables -C FORWARD -o "$AP_IFACE" -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -o "$AP_IFACE" -j ACCEPT

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow in on "$AP_IFACE" >/dev/null 2>&1 || true
    ufw route allow in on "$AP_IFACE" out on "$WIFI_IFACE" >/dev/null 2>&1 || true
    ufw route allow in on "$WIFI_IFACE" out on "$AP_IFACE" >/dev/null 2>&1 || true
  fi

  local waited=0
  while ((waited < STARTUP_VERIFY_TIMEOUT)); do
    wifi_is_connected && break
    sleep 2
    waited=$((waited + 2))
  done
  if ! wifi_is_connected; then
    restore_network "startup verification failed"
    rm -f "$LOCK_FILE"; trap - INT TERM; exit 1
  fi

  start_watchdog
  rm -f "$LOCK_FILE"
  trap - INT TERM

  log "Temporary hotspot active."
  echo
  echo "Temporary hotspot started."
  echo "  SSID:     ${HOTSPOT_SSID}"
  echo "  Channel:  ${channel}"
  echo "  Uplink:   ${SAVED_CONNECTION}"
  echo
  echo "Stop it anytime — WiFi returns to how it was before start."
  echo "If WiFi drops, the hotspot stops by itself and restores WiFi."
}

stop_hotspot() {
  restore_network "user requested stop"
}

show_status() {
  echo "=== Linux Mint Wifi Hotspot (temporary) ==="
  echo "WiFi:       $(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | head -n1 || echo unknown)"
  echo "Connection: $(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null | head -n1 || echo none)"
  echo "Internet:   $(internet_ok && echo OK || echo FAIL)"
  echo "Hotspot:    $(hotspot_is_active && echo ACTIVE || echo off)"
  if [[ -f "$STATE_FILE" ]]; then
    echo
    cat "$STATE_FILE"
  fi
  echo
  tail -n 10 "$LOG_FILE" 2>/dev/null || true
}

show_status_json() {
  local wifi_state conn internet hotspot
  wifi_state="$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | head -n1 || echo unknown)"
  conn="$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null | head -n1 || echo none)"
  internet_ok && internet=true || internet=false
  hotspot_is_active && hotspot=true || hotspot=false
  conn="${conn//\"/\\\"}"
  printf '{"wifi_state":"%s","connection":"%s","internet":%s,"hotspot_active":%s,"ssid":"%s","mode":"%s"}\n' \
    "$wifi_state" "$conn" "$internet" "$hotspot" "$HOTSPOT_SSID" \
    "$([[ -f $STATE_FILE ]] && echo temporary || echo off)"
}

save_config() {
  local ssid="${1:-}" password="${2:-}"
  [[ -n "$ssid" ]] && HOTSPOT_SSID="$ssid"
  [[ -n "$password" ]] && HOTSPOT_PASSWORD="$password"
  cat >"$CONF_FILE" <<EOF
# Temporary WiFi Hotspot — only active while you start it.

WIFI_IFACE=${WIFI_IFACE}
AP_IFACE=${AP_IFACE}
HOTSPOT_SSID=${HOTSPOT_SSID}
HOTSPOT_PASSWORD=${HOTSPOT_PASSWORD}
HOTSPOT_CON_NAME=${HOTSPOT_CON_NAME}

AP_GATEWAY=${AP_GATEWAY}
AP_DHCP_START=${AP_DHCP_START}
AP_DHCP_END=${AP_DHCP_END}

COUNTRY_CODE=${COUNTRY_CODE:-FR}

# Immediate yield when WiFi drops (temporary AP)
ENABLE_WATCHDOG=1
CHECK_INTERVAL=${CHECK_INTERVAL:-5}
FAIL_THRESHOLD=${FAIL_THRESHOLD:-1}
STARTUP_VERIFY_TIMEOUT=${STARTUP_VERIFY_TIMEOUT:-30}
AP_TEARDOWN_SETTLE=${AP_TEARDOWN_SETTLE:-2}

STATE_DIR=${STATE_DIR}
LOG_FILE=${LOG_FILE}
EOF
  echo "Config saved."
}

preflight() {
  echo "=== Preflight ==="
  command -v nmcli >/dev/null && echo "NetworkManager: OK" || echo "NetworkManager: MISSING"
  command -v hostapd >/dev/null && echo "hostapd: OK" || echo "hostapd: MISSING"
  command -v dnsmasq >/dev/null && echo "dnsmasq: OK" || echo "dnsmasq: MISSING"
  echo "WiFi: $(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | head -n1)"
  adapter_supports_concurrent_ap && echo "AP+STA: YES" || echo "AP+STA: NO"
  internet_ok && echo "Internet: OK" || echo "Internet: FAIL"
  echo "Mode: temporary only (does nothing until you Start; restores on Stop/disconnect)."
}

main() {
  local cmd="${1:-status}"
  if needs_root "$cmd" && [[ $EUID -ne 0 ]]; then
    ensure_root "$@"
  fi
  case "$cmd" in
    start) start_hotspot ;;
    stop) stop_hotspot ;;
    restart) restore_network "restart" || true; sleep 1; start_hotspot ;;
    status) show_status ;;
    restore) restore_network "manual restore" ;;
    preflight) preflight ;;
    status-json) show_status_json ;;
    save-config) save_config "${2:-}" "${3:-}" ;;
    _watchdog) watchdog_loop ;;
    *)
      echo "Usage: $0 {start|stop|restart|status|status-json|restore|preflight|save-config}" >&2
      exit 1
      ;;
  esac
}

main "$@"
