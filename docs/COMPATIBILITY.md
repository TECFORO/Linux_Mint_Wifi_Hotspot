# Compatibility & dependency updates

This file is the place to record what changes when **Linux Mint / Ubuntu base / kernel / Wi‑Fi drivers** update, so the app keeps installing and working.

The working approach (do not regress):
- Concurrent **AP + client** on one radio via a virtual interface (`ap0`) + `hostapd` + `dnsmasq` + NAT when Wi‑Fi is already connected
- Standalone AP on `wlo1` via `hostapd` when there is no Wi‑Fi client (Mint-like) — **never** leave NetworkManager `mode=ap` profiles behind
- **Never** use `nmcli device wifi hotspot` (creates leftover AP profiles that block client Wi‑Fi)
- Same **channel** as the active Wi‑Fi client for concurrent mode (required when `#channels <= 1`)
- Watchdog yields the AP if uplink disconnects or Wi‑Fi radio is disabled
- Firewall/`ufw` allow rules on the AP interface so phones can get DHCP
- Hard rule: stop/restore must always leave the Wi‑Fi client path clear

---

## Current verified baseline

| Field | Value |
|-------|--------|
| App version | see `VERSION` |
| Distro | Linux Mint **22.3** (Zena) |
| Ubuntu base | **noble** (24.04) |
| Reference chip | Realtek **RTL8852AE** (`rtw89_8852ae`) |
| Known-good package pins | `dependencies/versions-known-good.txt` |
| Apt install list | `dependencies/apt-packages.txt` |
| Phone tested | Samsung Galaxy Z Fold 3 (after firewall + `ieee80211w=0` fixes) |

### Mint 22.3 (Zena) — verified

- [x] Date tested: 2026-08-25
- [x] Concurrent AP keeps client Wi‑Fi up
- [x] Phone can join after UFW/`ap0` allow + PMF disabled
- [x] Notes: do not use NetworkManager hotspot on the uplink iface; `W00…` SSIDs nearby are unrelated neighbors
- [x] 2026-09-02: Watchdog must **not** call `pkexec restore` on flaky ping — only restore when WiFi is actually disconnected; keep watchdog as root after start so no password dialogs
- [x] 2026-09-14 (v1.3.0): Leftover NM `Hotspot` (`mode=ap` on `wlo1`) blocked joining other networks. Hard rule: purge all AP-mode NM profiles on stop/restore; dual mode concurrent + standalone; watchdog yields AP on disconnect/radio-off. Rollback snapshot still at `../wifi-hotspot-backup-2026-09-13-v1.1.0/`
- [x] 2026-09-16 (v1.4.0): User request — reset innate WiFi (keep passwords): cleared `hidden=yes` on CheickK/LASSANAKANTE/LASSANAKANTE2/TTSS(S) that forced aggressive scanning; normalized invalid `rtw89` modprobe option. Hotspot redesigned as **temporary only**: snapshot pre-AP WiFi, share while Start is on, on Stop or disconnect immediately restore snapshot. No standalone AP mode.

Update `versions-known-good.txt` after you confirm a working install on a new Mint release:

```bash
. /etc/os-release
echo -e "linuxmint\t${VERSION_ID}\nubuntu_codename\t${UBUNTU_CODENAME}" 
dpkg -l hostapd dnsmasq iw iptables network-manager policykit-1 python3-gi gir1.2-gtk-3.0 \
  | awk '/^ii/{printf "%s\t%s\n",$2,$3}'
```

---

## Checklist when Mint / the system changes

Copy this block for each upgrade you care about:

### Template — Mint __.__ (codename ______)

- [ ] Date tested: ____-__-__
- [ ] Kernel: `uname -r` → ________
- [ ] Wi‑Fi driver / chip: `lspci -nnk | grep -A3 -i network` → ________
- [ ] `iw phy` still reports `managed` + `AP` with `#channels <= 1` (or document new limits)
- [ ] Refresh `dependencies/apt-packages.txt` if any package was renamed/split
- [ ] Refresh `dependencies/versions-known-good.txt` with working `dpkg` versions
- [ ] `sudo ./install.sh` completes
- [ ] Hotspot starts **without** dropping client Wi‑Fi
- [ ] Phone (Android / iOS) associates, gets DHCP (`~/.local/share/linux-mint-wifi-hotspot/dnsmasq.leases`)
- [ ] Internet works on the phone (NAT / `ufw` still OK)
- [ ] `linux-mint-wifi-hotspot stop` / watchdog restore still bring Wi‑Fi back
- [ ] Notes / breakage / workarounds:

```
(write here)
```

---

## Known risk areas (watch these after upgrades)

1. **NetworkManager** — new NM versions may re-manage `ap0`; keep `nmcli device set ap0 managed no`.
2. **hostapd / nl80211** — Realtek `rtw89` concurrent AP quirks; channel must match client.
3. **dnsmasq** — Mint may ship dnsmasq as a system service; this app runs a **separate** instance bound only to `ap0` (do not stop system DNS blindly).
4. **UFW / nftables** — default deny can block DHCP on `ap0`; installer/runtime opens `ap0` INPUT/FORWARD.
5. **PolicyKit** — path in `packaging/com.local.linux-mint-wifi-hotspot.policy` must match install prefix (`/opt/linux-mint-wifi-hotspot/bin/wifi-hotspot.sh`).
6. **GTK / PyGObject** — GUI needs `python3-gi` + `gir1.2-gtk-3.0` (GTK4 migration would need a GUI rewrite; track here if Mint drops GTK3 bindings).

---

## How to bump the app after a compatibility change

1. Edit code under `src/` as needed.
2. Add a dated section above under “Checklist…”.
3. Update `dependencies/*` if packages or known-good versions changed.
4. Bump `VERSION` (semver: patch for fixes, minor for Mint-support additions).
5. Reinstall: `sudo ./install.sh`
