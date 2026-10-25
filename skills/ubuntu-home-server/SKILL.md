---
name: ubuntu-home-server
description: 'Use when working on the headless Ubuntu home server that hosts pet projects: rebuilding, reinstalling or recovering it (install from the USB, WiFi/netplan + systemd-networkd, finding it on the LAN, pinning its IP, driving it from Windows), deploying or changing an app on it (Docker, /srv/<app>, ports), its backups (restic, SQLite hooks, the Samba share for Home Assistant backups), auto-updates and reboots, monitoring (Beszel, Glances to Home Assistant), laptop power settings, and remote access (Tailscale, T3 Code + Claude Code sessions from the phone). The actual host name, IP, user, SSID and key live in the private global CLAUDE.md, not here.'
version: 1.1.0
compatibility: 'Server: Ubuntu Server 24.04+/26.04 (netplan + systemd-networkd, no NetworkManager). Driven from Windows 11 with PowerShell + Git Bash OpenSSH; password-sudo scripted via Python + paramiko.'
---

# Ubuntu home server

A headless Ubuntu Server laptop used as a general host for pet projects. This skill is the
**rebuild runbook** and the **operations reference** for it: getting a wiped or dead box back
to a *reachable, networked* server fast, and then everything that runs on it, without
re-deriving what was learned the hard way the first time.

> **Personal specifics live elsewhere.** This file is public and generic. The real host
> name, LAN IP, login user, WiFi SSID, interface name, MAC and SSH key path are recorded in
> the **private global `CLAUDE.md`** (`~/.claude/CLAUDE.md`). Read that first for the
> concrete values, then follow the procedure here with them substituted for the
> `<PLACEHOLDERS>`.

Placeholders used below: `<USER>`, `<SERVER_IP>`, `<SUBNET>` (e.g. `192.168.128.0/23`),
`<GATEWAY>`, `<WIFI_IFACE>` (e.g. `wlp0s20f3`), `<SSID>`, `<MAC>`, `<KEY>` (local path to the
SSH private key).

## When to use this skill

- Reinstalling Ubuntu on the server from scratch, or recovering it after a failure.
- The box boots but has no network / WiFi won't come up.
- You can't find the box on the LAN, or SSH to it suddenly fails.
- You need to drive it (run sudo commands, edit config) remotely from Windows.
- You want to pin its IP address.
- You're deploying a new app to it, or changing how an existing one is deployed or backed up.
- Backups, auto-updates, the nightly reboot, monitoring or the laptop's power settings.
- You want to reach its apps away from home (Tailscale, not port forwarding), or run
  Claude Code / T3 Code agent sessions on it from a phone.

## Where to look

Read only the file the task needs:

| File | Covers |
| --- | --- |
| [references/rebuild.md](references/rebuild.md) | Windows-side prerequisites, then §1–§9: install from the USB, find the box on the LAN, install your key, sudo over paramiko and going key-only (`scripts/keys_only.py`), the netplan WiFi fix, cloud-init, applying netplan safely, DHCP reservation, WiFi-only checkout |
| [references/hardware-power.md](references/hardware-power.md) | Lid closed, power back on after an outage, battery charge cap, NVIDIA driver under Secure Boot, growing the root volume to the whole SSD |
| [references/updates-backups.md](references/updates-backups.md) | unattended-upgrades with auto-reboot, restic to the SD card and its HA webhook report, the Samba share for Home Assistant's backups |
| [references/deploying-apps.md](references/deploying-apps.md) | Docker install, the `/srv/<app>` shape, building on the box, healthchecks, SQLite backup hooks and excludes, static sites, retiring an old host, ports |
| [references/remote-access.md](references/remote-access.md) | Tailscale, Tailscale Serve (one HTTPS port per app), T3 Code + Claude Code as a separate no-sudo user, GitHub token for it |
| [references/monitoring.md](references/monitoring.md) | Beszel hub + agent, Glances REST API into Home Assistant |

On a full rebuild, go through `rebuild.md` top to bottom, then `hardware-power.md`, then the
rest in the order the box needs them (updates, Docker, backups, apps, remote access,
monitoring).

## Services & projects

Each project that lands on the box gets a short entry in the private `CLAUDE.md`: what it
is, its port, how it's deployed, and anything shared-infrastructure-sensitive — same spirit
as the Pi's entry there. Treat the box as shared: don't repurpose ports, reboot, or
reconfigure networking without checking what else depends on it. Every app follows the
shape in [references/deploying-apps.md](references/deploying-apps.md), so backups, reboots
and secrets need no per-app thought.

---

## Gotchas (quick reference)

- **Keyboard-layout trap (install time).** BE and FR AZERTY share all *letter* keys but
  differ on the number/symbol row. The key that types `-` on **Belgian** AZERTY (the US
  `=`/`+` position) types `=` on **French** AZERTY. A password typed under the wrong layout
  is stored as different characters. Verify the layout before typing the install password; if
  you're later locked out, try swapping `-`↔`=` (and other symbol keys) between the two
  layouts. To fix a box installed with the wrong layout, set `XKBLAYOUT="be"` /
  `XKBVARIANT=""` in `/etc/default/keyboard` (over SSH, `sudo localectl set-x11-keymap` is
  refused by polkit), then `sudo setupcon -k --force </dev/tty1 >/dev/tty1` to reload the
  console. The stored password doesn't change, so at the console type it as it was
  *stored*.
- **`match:` WiFi bug** → `netplan generate` fails entirely → no WiFi, every boot. Define the
  WiFi interface by name ([rebuild.md](references/rebuild.md) §5).
- **cloud-init reverts netplan edits on reboot** → disable its network config ([rebuild.md](references/rebuild.md) §6).
- **`netplan apply` drops your SSH link** → run detached + log to a file ([rebuild.md](references/rebuild.md) §7).
- **Closing the lid suspends the box** by default → logind drop-in + mask sleep targets ([hardware-power.md](references/hardware-power.md)).
- **No NetworkManager/`nmcli`/`iw`/`rfkill`** on this box — it's networkd + wpa_supplicant.
- **`sed` under `set -e` can abort silently** → re-read files after editing; prefer Python.
- **Stale `known_hosts`** after DHCP reuse → `ssh-keygen -R <ip>` (symptom can be a misleading
  "Connection closed", not just "Host key verification failed").
- **Scan the full `/23`**, not one `/24`, when hunting for the box.
- **Secrets:** never persist a password to disk (classifier blocks it); read from the
  clipboard in memory. Mask secrets in any command output you print
  (`sed -E 's/(password:).*/\1 ****/'`). The WiFi passphrase lives **cleartext** in the
  root-only netplan file — that's normal for netplan, just don't leave that file
  world-readable.
- **Password sudo is bootstrap-only** → run `scripts/keys_only.py` once the box is reachable ([rebuild.md](references/rebuild.md) §4).
- **sshd drop-ins: first value wins** → name overrides `00-…` so they beat `50-cloud-init.conf`.
- **Pasting a command clobbers a password on the clipboard** → copy the secret last, then type
  or recall the command.
- **paramiko:** key-based connect + `sudo -S -p ""` for sudo; no `get_pty()`; base64 file
  bodies over the channel; auth errors don't distinguish user vs password.
- **Remote access = Tailscale**, never a router port forward ([remote-access.md](references/remote-access.md)). Disable the server's key
  expiry, and add Tailscale's repo to unattended-upgrades.
- **Agent user:** no sudo, no docker group. Give it its own `~/.claude/CLAUDE.md` saying
  where it runs and what it may not do, because the dev PC's global instructions don't
  travel. `sudo -iu <user> …` expands `~` as the caller, so use full paths.
- **Secrets piped from PowerShell gain a `\r`.** Strip it on the box.
