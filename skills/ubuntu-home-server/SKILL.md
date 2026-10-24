---
name: ubuntu-home-server
description: 'Use when setting up, rebuilding, reinstalling, or recovering the headless Ubuntu home server — installing it from the USB, getting WiFi/networking up (netplan + systemd-networkd), finding the box on the LAN, pinning its IP via a DHCP reservation, or driving it remotely from a Windows PC. This is the rebuild runbook; the actual host name, IP, user, SSID and key live in the private global CLAUDE.md, not here.'
version: 1.0.0
compatibility: 'Server: Ubuntu Server 24.04+/26.04 (netplan + systemd-networkd, no NetworkManager). Driven from Windows 11 with PowerShell + Git Bash OpenSSH; password-sudo scripted via Python + paramiko.'
---

# Ubuntu home server

A headless Ubuntu Server laptop used as a general host for pet projects. This skill is the
**rebuild runbook**: the laptop was wiped or died, and you need it back to a *reachable,
networked* box fast — without re-deriving everything learned the hard way the first time.
It reads top to bottom, from a flashed installer USB to a verified WiFi-only server.

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

## Prerequisites (the Windows side)

- **Git Bash** — its OpenSSH scripts cleanly (`ssh`, `ssh-keygen`, `ssh-keyscan`). Windows'
  bundled `ssh.exe` also works here (no MAC-algorithm workaround needed, unlike the Pi).
- **Python + paramiko** for scripted password-sudo (Windows OpenSSH can't answer a password
  prompt non-interactively, and there's no `sshpass`/`plink`):
  ```bash
  python -m pip install --user paramiko
  ```
- An existing SSH keypair to install on the box (reusing an existing deploy key is fine; the
  specific key path is in the private `CLAUDE.md`).

---

## 1. Install from the USB

Boot the installer and run through subiquity (the Ubuntu Server installer). Three things
matter:

1. **Check the keyboard layout BEFORE typing any password.** See the keyboard-layout trap
   in Gotchas — a password typed under the wrong AZERTY variant is silently stored as
   *different characters*, and you won't find out until you can't log in.
2. **Enable "Install OpenSSH server"** on the SSH page. On a headless box this is the only
   way in. Without it you're stuck with a keyboard and monitor.
3. **Don't rely on the installer's WiFi.** Subiquity *will* let you join WiFi and will save
   it, but it writes the config in a form that breaks on every boot (see §5). Expect to fix
   networking after first boot. If you have an Ethernet cable, plug it in for the install and
   first contact; it makes everything below easier.

---

## 2. Find the box on the LAN (from Windows)

The box comes up with a DHCP address you don't know yet. Scan the **whole subnet** (mind the
`/23` — that's two `/24`s, `.128.x` *and* `.129.x`) for SSH servers and read their banners;
the Ubuntu box identifies itself:

```powershell
$ips = foreach($a in 128..129){ foreach($b in 1..254){ "192.168.$a.$b" } }
$ips | ForEach-Object -Parallel {
  $c = [System.Net.Sockets.TcpClient]::new()
  try {
    if ($c.ConnectAsync($_,22).Wait(400) -and $c.Connected) {
      $s=$c.GetStream(); $s.ReadTimeout=1500; $buf=New-Object byte[] 256
      $n=0; try { $n=$s.Read($buf,0,256) } catch {}
      "$_ " + [Text.Encoding]::ASCII.GetString($buf,0,$n).Trim()
    }
  } catch {} finally { $c.Dispose() }
} -ThrottleLimit 128
```

The Ubuntu box shows a banner like `SSH-2.0-OpenSSH_10.2p1 Ubuntu-...`; other hosts (a Pi,
printers) look different. To re-find it by MAC after an IP change, refresh ARP and look it
up:

```powershell
1..254 | ForEach-Object -Parallel { $null = Test-Connection "192.168.129.$_" -Count 1 -TimeoutSeconds 1 -Quiet } -ThrottleLimit 128 | Out-Null
Get-NetNeighbor -AddressFamily IPv4 | Where-Object LinkLayerAddress -eq '<MAC>'
```

---

## 3. First contact & installing your key

First login is password-based. Confirm which auth methods are offered, then install your key
so everything afterward is key-based (far more robust — see the clipboard note in §4):

```bash
ssh-copy-id -i <KEY>.pub <USER>@<SERVER_IP>
# then verify:
ssh -i <KEY> -o BatchMode=yes <USER>@<SERVER_IP> 'echo ok as $(whoami)'
```

If `ssh-copy-id` isn't available from your shell, append the `.pub` line to
`~/.ssh/authorized_keys` over a password session (paramiko can do this — see §4).

**`known_hosts` staleness (bites after any IP change / DHCP reuse):** if SSH fails with
`Host key verification failed` — or a confusing `Connection closed by <ip> port 22` right
after the box changed address — the IP is remembered against a *different* device's key.
Clear it and reconnect:

```bash
ssh-keygen -R <SERVER_IP>
# sanity-check the box presents the SAME key on each of its addresses:
ssh-keyscan -t ed25519 <SERVER_IP> 2>/dev/null | ssh-keygen -lf -
```

---

## 4. Driving the box from Windows (sudo over paramiko)

`sudo` on the box needs a password (not NOPASSWD), and Windows OpenSSH can't feed a password
prompt non-interactively. Pattern that works: **connect key-based**, then run a root shell
with `sudo -S` and feed the password on stdin.

```python
import sys, base64, os, paramiko
HOST, USER = "<SERVER_IP>", "<USER>"
KEY = os.path.expanduser("<KEY>")
pw = sys.stdin.readline().rstrip("\r\n")      # password read from clipboard, in memory only

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, key_filename=KEY, look_for_keys=False, allow_agent=False, timeout=10)

chan = c.get_transport().open_session()
chan.settimeout(60)                            # do NOT get_pty(): a pty hangs on pagers
chan.exec_command('sudo -S -p "" bash -s')     # -p "" suppresses the prompt text
chan.sendall((pw + "\n").encode())             # password first...
chan.sendall(b'export SYSTEMD_PAGER=;\n')      # disable pagers so systemctl/journalctl can't hang
chan.sendall(b'<<< your root commands here >>>\n')
chan.shutdown_write()
out = b""
while True:
    d = chan.recv(4096)
    if not d: break
    out += d
print(out.decode(errors="replace"))
c.close()
```

Run it feeding the password from the clipboard, in memory — never written to disk:

```powershell
Get-Clipboard -Raw | python script.py
```

Key rules, each learned the hard way:

- **Connect with the key, not the password.** The clipboard contents change between steps; a
  password-based *connect* breaks the moment the clipboard is overwritten. Keys don't.
- **Never write the password to a file.** The auto-mode guard blocks it as credential
  leakage. Pipe `Get-Clipboard` into the script's stdin instead.
- **Two secrets at once?** Put them on the clipboard as **two lines** (e.g. login password
  on line 1, WiFi passphrase on line 2) and read both from stdin. This avoids clipboard
  collisions when you need the sudo password *and* another secret in one run.
- **Don't `get_pty()`** — it makes `systemctl`/`journalctl` hang on their pager. Set
  `SYSTEMD_PAGER=` / use `--no-pager` instead.
- **base64-encode file bodies and scripts** you send over the channel (YAML, the SSID, the
  passphrase). It sidesteps every shell-quoting problem with special characters:
  `echo <B64> | base64 -d > /etc/netplan/....yaml`.
- A paramiko `AuthenticationException` is **identical for wrong-username and wrong-password**.
  Don't guess which, and never brute-force — confirm the exact user/password with the human.

### Then: go key-only with passwordless sudo

The clipboard routine above is only needed while bootstrapping. Once the box is reachable,
switch it to **a dedicated key, NOPASSWD sudo and no password SSH**, and from then on it's
plain `ssh -i <NEW_KEY> <USER>@<SERVER_IP> 'sudo …'`. With password login off, the key is the
security boundary. Give this box **its own key** and don't reuse a key that unlocks other
machines, so a lost key exposes one machine only.

`scripts/keys_only.py` does it in one run. The human runs it from the Claude Code prompt with
`!`: auto mode blocks *Claude* from installing keys and granting root (it calls that
"unauthorized persistence"), and that decision rightly belongs to the human. Copy the sudo
password to the clipboard, then **type or recall** the command. Pasting the command overwrites
the clipboard, and sudo then fails with three "Authentication failed" messages, because it
reads the next script lines as two more password attempts.

```
! python <skills>/ubuntu-home-server/scripts/keys_only.py <SERVER_IP> <USER> --bootstrap-key <KEY> --key ~/.ssh/<NEW_KEY>
```

Each step checks its result before the next one can change access, and a re-run skips what's
done: create the key → install it and test it → write the sudoers drop-in (checked with
`visudo -c` before it's moved into place) and `sshd_config.d/00-keys-only.conf` → require
`sudo -n` in a fresh session → only then remove the bootstrap key → confirm the server offers
only `publickey`. The sshd drop-in must sort **before** `50-cloud-init.conf`: sshd keeps the
*first* value it reads, and cloud-init's file can set `PasswordAuthentication yes`.

You can't lock yourself out this way. A console login still takes the password, and sudo works there.

---

## 5. The core WiFi fix (netplan + networkd)

**Symptom:** WiFi interface stays `DOWN`/`NO-CARRIER`; `netplan generate` fails with:

```
ERROR: <WIFI_IFACE>: networkd backend does not support wifi with match:, only by interface name
```

**Cause:** subiquity writes the WiFi netdef in `/etc/netplan/00-installer-config.yaml` using
`match: {macaddress: ...}` + `set-name:`. netplan's **networkd** backend rejects WiFi defined
by `match:`, so `netplan generate` fails *entirely* — every boot — and WiFi never comes up.

**Fix:** define the interface **by name** and drop the whole `match:` block and `set-name:`.
The working file looks like:

```yaml
network:
  version: 2
  wifis:
    <WIFI_IFACE>:
      dhcp4: true
      optional: true
      access-points:
        "<SSID>":
          password: "<WIFI_PASSPHRASE>"
```

Edit it robustly — a `sed` under `set -e` once aborted silently and left the file unchanged,
so **always re-read the file after editing**. A small Python pass that strips the indented
`match:` block by indentation is more reliable than line-delete regexes:

```python
lines = open(p).read().splitlines(); out=[]; i=0
while i < len(lines):
    ln=lines[i]; s=ln.strip()
    if s == "match:":
        indent=len(ln)-len(ln.lstrip()); i+=1
        while i < len(lines):
            s2=lines[i]; ind2=len(s2)-len(s2.lstrip())
            if s2.strip()=="" or ind2>indent: i+=1
            else: break
        continue
    if s.startswith("set-name:"): i+=1; continue
    out.append(ln); i+=1
open(p,"w").write("\n".join(out)+"\n")
```

**This box has no NetworkManager** — no `nmcli`, no `iw`, no `rfkill` tool. It's pure
networkd + `wpa_supplicant`. Ignore any guide that reaches for NetworkManager.

---

## 6. Make the fix survive reboot (cloud-init)

**cloud-init regenerates `/etc/netplan/*.yaml` on boot** from its own stored config, so a
hand-edit to `00-installer-config.yaml` gets *reverted* on the next boot (tell-tale: the file
is back to the `match:` form, with a `.bak` sitting next to it). Disable cloud-init's network
management so your edit sticks:

```bash
echo "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
```

Do this **before or together with** the §5 edit, or you'll fix WiFi and lose it on reboot.

---

## 7. Apply without killing your own session

`netplan apply` restarts `systemd-networkd`, which **blips the link you are connected over**.
If you run apply + checks as one in-band command, the output is lost to pipe buffering and you
get silence. Run it **detached**, logging to a file, then reconnect and read the log:

```bash
# (as root, e.g. via the §4 paramiko pattern)
setsid bash -c '
  netplan generate 2>&1
  netplan apply 2>&1
  for i in $(seq 1 20); do ip -4 -br addr show <WIFI_IFACE> | grep -q "[0-9]" && break; sleep 2; done
  { echo IFACE:; ip -br addr show <WIFI_IFACE>;
    echo ROUTE:; ip route | grep <WIFI_IFACE>;
    echo PING:;  ping -c3 -W2 1.1.1.1;
    echo DNS:;   ping -c2 -W2 archive.ubuntu.com; } 
' >/tmp/np.log 2>&1 </dev/null &
```

Then, from Windows, wait and read it (key-based, no sudo needed for these reads):

```bash
ssh -i <KEY> -o BatchMode=yes <USER>@<SERVER_IP> 'sleep 40; cat /tmp/np.log'
```

**Verification battery** — don't declare success on one check:
`ip -br addr` (has an IP), `ip route | grep <WIFI_IFACE>` (default route via WiFi), raw ping
`1.1.1.1` (connectivity), and a **DNS** ping like `archive.ubuntu.com` (resolution works).

---

## 8. Pin the address (DHCP reservation)

Give the box a stable address so bookmarks and SSH configs keep working.

**Prefer a DHCP reservation on the router** over a device-set static IP (no conflict risk).
But note two things seen on a consumer ISP gateway:

- The router's **local admin UI may be firewalled off the WiFi segment** (ports 80/443/8080/
  8443 all closed from the client). In that case you manage reservations through the **ISP's
  cloud portal / app**, not `http://<GATEWAY>`. The actual portal + menu path is in the
  private `CLAUDE.md`.
- A reservation must sit **inside** the router's private DHCP pool. (The inverse rule applies
  only if you ever set a static IP *on the device itself* — that must sit *outside* the pool.)
  Picking the device by name in the portal usually auto-fills its MAC and IP.

After reserving: if the current lease already equals the reserved address, there's nothing to
do. Otherwise force a renew:

```bash
sudo networkctl renew <WIFI_IFACE>     # or: sudo systemctl restart systemd-networkd
```

**Static-in-netplan alternative** (if you can't do a reservation) — pick an address *outside*
the DHCP pool and add to the WiFi netdef:

```yaml
      dhcp4: false
      addresses: [<STATIC_IP>/<PREFIX>]
      routes: [{to: default, via: <GATEWAY>}]
      nameservers: {addresses: [<GATEWAY>]}
```

---

## 9. WiFi-only checkout

If the box is meant to run on WiFi alone, unplug Ethernet and confirm from Windows that it's
fully up on its **WiFi** address (which is a *different* IP than the Ethernet one — update any
bookmarks):

```bash
ssh -i <KEY> -o BatchMode=yes <USER>@<SERVER_IP> '
  hostname; ip -br addr | grep -vE "^lo";
  ip route | grep default;
  ping -c2 -W2 archive.ubuntu.com | tail -2'
```

### Keep running with the lid closed

Out of the box, logind **suspends on lid close**, and the server drops off the LAN ("Destination
host unreachable"). Open the lid (or press power) to wake it. Then, as root (plain `sudo` once
the box is key-only, otherwise via the §4 paramiko pattern):

```bash
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' \
  > /etc/systemd/logind.conf.d/lid.conf
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl restart systemd-logind   # safe over SSH; your session survives
```

Verify with the lid **actually** closed. A lid that isn't fully latched still reads `open`,
and then the test proves nothing:

```bash
cat /proc/acpi/button/lid/*/state                  # expect: closed
journalctl -u systemd-logind --since -10min | grep -i lid   # expect: "Lid closed."
```

Then confirm that it keeps answering pings from Windows for a minute or so.

### Don't keep the battery at 100%

An always-plugged laptop sitting at full charge wears its battery fast. ThinkPads (and
other laptops whose kernel driver exposes it) accept charge thresholds in sysfs. Set them
with a udev rule, so they're reapplied on every boot even if the firmware forgets:

```bash
echo 'ACTION=="add|change", SUBSYSTEM=="power_supply", KERNEL=="BAT0", ATTR{charge_control_start_threshold}="75", ATTR{charge_control_end_threshold}="80"' \
  | sudo tee /etc/udev/rules.d/90-battery-threshold.rules
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=power_supply --sysname-match=BAT0 --action=change
cat /sys/class/power_supply/BAT0/charge_control_{start,end}_threshold   # 75 / 80
```

A battery already above the cap stays there ("Not charging") until it's drained. To bring
it down now, write `force-discharge` to `charge_behaviour`, then `auto` once it's at the cap.

---

## 10. Services & projects

*(Grown as we deploy things to the box. Each project that lands here gets a short entry: what
it is, its port, how it's deployed, and anything shared-infrastructure-sensitive — same
spirit as the Pi's entry in the private `CLAUDE.md`. Treat the box as shared: don't repurpose
ports, reboot, or reconfigure networking without checking what else depends on it.)*

### Automatic updates

Out of the box, `unattended-upgrades` installs **security updates only**, so regular bug-fix
updates pile up in the "N updates available" count. Add a local override, and leave the
packaged `50unattended-upgrades` untouched so package upgrades don't conflict with it:

```
// /etc/apt/apt.conf.d/52unattended-upgrades-local
Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-updates";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

Verify with `sudo unattended-upgrade --dry-run --debug | grep "Allowed origins"`. The reboot
time is in the box's own time zone, which defaults to UTC. Set the local one with
`sudo timedatectl set-timezone Europe/Brussels`, which also puts log and dashboard
timestamps in local time. A few updates that remain are
**phased** ("deferred due to phasing"): Ubuntu rolls those out gradually, and they install
later by themselves. Auto mode refuses to set up this standing auto-update/auto-reboot
policy on Claude's behalf, so the human runs it.

### NVIDIA driver on a Secure Boot laptop

`sudo ubuntu-drivers install --gpgpu` installs the headless `*-server-open` driver. Its
kernel modules come prebuilt and signed by Canonical (`linux-modules-nvidia-*`), so you don't
have to enroll a MOK key at the console. Then install `nvidia-utils-<ver>-server` to get
`nvidia-smi`. The modules may target a **newer kernel** that apt pulled in at the same
time. That's fine: reboot into it. `sudo systemctl reboot` over SSH can take ~30 s to
actually go down, so check `uptime -s` afterwards instead of trusting that SSH answered.

### Beszel (monitoring dashboard)

Hub and agent run as binaries under systemd on the same box. The binary agent sees
temperatures, battery and GPUs better than the Docker one. Download each install script,
then run it:

```bash
curl -fsSL https://get.beszel.dev/hub -o install-hub.sh && sudo sh install-hub.sh -p 8090 --auto-update
PUB=$(sudo ssh-keygen -y -f /opt/beszel/beszel_data/id_ed25519)    # the hub's key
curl -fsSL https://get.beszel.dev -o install-agent.sh
sudo sh install-agent.sh -k "$PUB" -p 45876 --auto-update true </dev/null
```

Beszel isn't apt-managed, so unattended-upgrades never touches it. `--auto-update` (on
the hub script, `--auto-update` with no value) adds a daily `beszel-*-update.timer` that runs
`<binary> update`. If you installed without it, create the same `.service`/`.timer` pair
by hand: `OnCalendar=daily`, `RandomizedDelaySec=4h`, `Persistent=true`.

The agent script grants `DeviceAllow` for `/dev/nvidia*` automatically (so install the
NVIDIA driver first). Put everything else in one drop-in,
`/etc/systemd/system/beszel-agent.service.d/local.conf`:

```ini
[Service]
Environment="LISTEN=127.0.0.1:45876"                       # only the local hub needs it
AmbientCapabilities=CAP_PERFMON CAP_SYS_ADMIN CAP_SYS_RAWIO   # Intel GPU; NVMe S.M.A.R.T.
CapabilityBoundingSet=CAP_PERFMON CAP_SYS_ADMIN CAP_SYS_RAWIO # ambient caps missing here are dropped silently
DeviceAllow=/dev/nvme0 r
DeviceAllow=/dev/nvme0n1 r
SupplementaryGroups=docker                                  # container stats
```

That drop-in alone isn't enough:
- **Intel iGPU:** install `intel-gpu-tools` and set `kernel.perf_event_paranoid = 2` in
  `/etc/sysctl.d/`.
- **S.M.A.R.T.:** install `smartmontools`, and add a udev rule, because `/dev/nvme0` is
  `crw------- root`:
  `KERNEL=="nvme[0-9]*", GROUP="disk", MODE="0660"` in
  `/etc/udev/rules.d/90-nvme-disk-group.rules`. The installer already puts `beszel` in
  `disk`. Don't test with a plain `sudo -u beszel smartctl`: it lacks `CAP_SYS_ADMIN` and
  fails even when the service works. Check the hub's `smart_devices` table instead.

The human creates their own account at `http://<SERVER_IP>:8090` and adds a system with host
`localhost` and port `45876`. The agent's "invalid HUB_URL" warning is harmless in this
mode, because the hub connects to the agent over SSH.

### Disk: use the whole SSD

The Ubuntu Server installer's LVM layout gives the root volume only ~100 GB and leaves the
rest of the volume group unallocated. Before deploying anything, grow it while the box is
running: `sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv` (`-r` also grows the
ext4 filesystem).

### Backups (restic to a local SD card)

Convention: **every app lives in `/srv/<app>`**, with its compose file plus bind-mounted
data (not named volumes), so one backup path covers all apps. A database that can't be
copied while live gets a `/srv/<app>/backup-pre.sh` that dumps it first.

- **Card:** leave it FAT32, so that if the server dies you can restore the card on a Windows
  PC with `restic.exe`. restic works fine on vfat. Mount it by UUID in fstab with
  `nofail,x-systemd.device-timeout=10s,uid=0,gid=0,umask=077`, so a missing card doesn't
  block boot.
- **Repository:** `/etc/restic/env` holds `RESTIC_REPOSITORY` and `RESTIC_PASSWORD_FILE`. The
  password is from `openssl rand -base64 32`, kept root-only in `/etc/restic/password`. The
  human must copy it somewhere off the box (and from their own terminal, not through Claude),
  or the backups can't be restored once the box is gone.
- **Job:** `/usr/local/sbin/backup`, run by `backup.timer` at 03:00 (before the 04:00 update
  reboot), with `RequiresMountsFor=/mnt/backup`. It:
  1. copies live SQLite databases with the `sqlite3` backup API into `/var/backups/sqlite`,
     and excludes the live files;
  2. runs the per-app hooks;
  3. runs `restic backup --one-file-system /etc /srv /home /root /var/backups /opt/beszel`;
  4. runs `forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6`;
  5. runs `check --read-data-subset=2%`.
- **Prove it:** after the first run, restore a config file and a database copy to `/tmp` and
  open them.
- **Pitfall when scripting it:** `sudo env $(cat /etc/restic/env) …` fails, because the
  `$(cat)` runs as your user and can't read the root-only directory. Source the file
  inside `sudo bash`.

A card in the same machine guards against SSD failure, bad updates and mistakes, but not
against theft, fire or the laptop dying with the card inside. Add an off-site copy for data
that really matters.

### Docker

Install from Docker's own apt repo (`/etc/apt/keyrings/docker.asc` plus a deb822
`/etc/apt/sources.list.d/docker.sources`; it supports Ubuntu 26.04). Install `docker-ce`,
`docker-ce-cli`, `containerd.io`, `docker-buildx-plugin` and `docker-compose-plugin`. Write
`/etc/docker/daemon.json` **before** the first container starts:

```json
{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }
```

Give every app `restart: unless-stopped`, because unattended-upgrades reboots the box at
04:00 when an update requires it. Docker's repo isn't among unattended-upgrades' origins,
so Docker itself only updates when you upgrade it by hand.

### Glances → Home Assistant

Beszel can't send data to HA. Its HA add-ons do the opposite: they put an agent on the HA
machine itself. HA has a native **Glances** integration instead. The apt package's service
runs the old XML-RPC server on localhost, so override it to serve the REST API:

```bash
sudo apt-get install -y --no-install-recommends glances python3-uvicorn python3-jinja2 python3-pynvml python3-docker lm-sensors
sudo mkdir -p /etc/systemd/system/glances.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/glances -w --disable-webui -B 0.0.0.0 -p 61208\nRestart=on-failure\n' \
  | sudo tee /etc/systemd/system/glances.service.d/api.conf
sudo systemctl daemon-reload && sudo systemctl restart glances
curl -s http://<SERVER_IP>:61208/api/4/pluginslist     # gpu, sensors, containers listed?
```

Then add the integration in HA: Settings → Devices & services → Glances, with host
`<SERVER_IP>` and port `61208`. Or use the REST config flow:
`POST /api/config/config_entries/flow {"handler":"glances"}`, then post `host`, `port`, `ssl`
and `verify_ssl` to the flow. You get sensors for CPU, memory, disk, every temperature, fan,
battery, the NVIDIA GPU (via `python3-pynvml`) and, once Docker runs, containers. The API
has no authentication, so it stays LAN-only.

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
  WiFi interface by name (§5).
- **cloud-init reverts netplan edits on reboot** → disable its network config (§6).
- **`netplan apply` drops your SSH link** → run detached + log to a file (§7).
- **Closing the lid suspends the box** by default → logind drop-in + mask sleep targets (§9).
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
- **Password sudo is bootstrap-only** → run `scripts/keys_only.py` once the box is reachable (§4).
- **sshd drop-ins: first value wins** → name overrides `00-…` so they beat `50-cloud-init.conf`.
- **Pasting a command clobbers a password on the clipboard** → copy the secret last, then type
  or recall the command.
- **paramiko:** key-based connect + `sudo -S -p ""` for sudo; no `get_pty()`; base64 file
  bodies over the channel; auth errors don't distinguish user vs password.
