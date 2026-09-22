# Linux_Mint_Wifi_Hotspot (experimental)

> **Experimental software.** This app temporarily reconfigures Wi‑Fi (virtual AP interface, `hostapd`, DHCP, NAT, firewall).  
> **Do not use it if you need a guaranteed-stable network** (work VPN, critical uplink, production subnet, exams, etc.).  
> Use at your own risk. Prefer a spare machine when trying it the first time.

Share your **current** Wi‑Fi connection while staying connected (similar idea to Windows Mobile Hotspot), on **Linux Mint / Ubuntu / Debian** with NetworkManager.

It creates a virtual AP (`ap0`) + `hostapd` / `dnsmasq` + NAT. It does **not** use NetworkManager’s built-in hotspot mode (that would drop your uplink).

---

## What you see here vs what gets installed

| On GitHub (this folder) | After someone runs `sudo ./install.sh` |
|-------------------------|----------------------------------------|
| Source code, README, LICENSE, docs | Copied into `/opt/linux-mint-wifi-hotspot/` |
| `dependencies/apt-packages.txt` | Used once to `apt-get install` packages |
| `packaging/*.desktop`, PolicyKit | Installed under `/usr/share/...` and `/etc/polkit-1/` |
| This README | **Not** shown as an app window — people read it on GitHub |

The README is **one file** (`README.md`). It is documentation for humans (and for GitHub’s project page). The installer does **not** paste this text into the desktop app.

---

## Is it stable?

**Not fully.** Fine for casual phone tethering on a known-good Mint/Ubuntu setup with a concurrent-capable Wi‑Fi chip. Still experimental: drivers, NetworkManager, and firewalls change, and many chips cannot do AP+client at once.

## Can it be reverted?

**Yes (temporary AP only):**

1. Stop in the GUI, or `linux-mint-wifi-hotspot stop` / `restore`
2. Wi‑Fi disconnect → watchdog restores the pre-start connection
3. Failed start → restore
4. `sudo ./uninstall.sh` (optional `--purge-deps`)

If the Wi‑Fi **driver/firmware** locks up, reboot may still be needed.

## Distros

| Distro | Expectation |
|--------|-------------|
| Linux Mint 22.x | Primary test platform |
| Ubuntu 22.04 / 24.04 | Should work |
| Debian + NetworkManager | Likely OK; test first |
| Fedora / Arch / NixOS | Not supported by this installer |

See `dependencies/` and `docs/COMPATIBILITY.md`.

---

## Install

```bash
cd Linux_Mint_Wifi_Hotspot
sudo ./install.sh
sudo nano /etc/linux-mint-wifi-hotspot/wifi-hotspot.conf   # set HOTSPOT_PASSWORD (8+ chars)
linux-mint-wifi-hotspot-gui                               # or menu: “Linux Mint Wifi Hotspot”
linux-mint-wifi-hotspot start|stop|status|restore
```

### Uninstall

```bash
sudo ./uninstall.sh
sudo ./uninstall.sh --purge-deps
```


## License

[MIT](LICENSE) — provided **as is**, with no warranty. Network disruption risk is yours.
