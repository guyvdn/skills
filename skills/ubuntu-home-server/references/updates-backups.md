# Updates & backups

Part of the [ubuntu-home-server](../SKILL.md) skill. Placeholders (`<USER>`, `<SERVER_IP>`, …) are
listed there; the real values are in the private global `CLAUDE.md`.

Unattended upgrades and reboots, restic to the SD card, and the Samba share that takes
Home Assistant's backups off its own disk.

## Automatic updates

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
Unattended-Upgrade::Automatic-Reboot-Time "05:00";
```

Verify with `sudo unattended-upgrade --dry-run --debug | grep "Allowed origins"`. The reboot
time is in the box's own time zone, which defaults to UTC. Set the local one with
`sudo timedatectl set-timezone Europe/Brussels`, which also puts log and dashboard
timestamps in local time. Pick a reboot time after every nightly job has finished: the
backup runs at 03:00, and an app's own nightly batch (one starts at 03:30 and runs 20+
minutes) would be cut off by a 04:00 reboot, hence 05:00. A few updates that remain are
**phased** ("deferred due to phasing"): Ubuntu rolls those out gradually, and they install
later by themselves. Auto mode refuses to set up this standing auto-update/auto-reboot
policy on Claude's behalf, so the human runs it.

## Backups (restic to a local SD card)

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
- **Job:** `/usr/local/sbin/backup`, run by `backup.timer` at 03:00 (before the 05:00 update
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

**Report results to Home Assistant.** Rename the job to `backup-run` and make
`/usr/local/sbin/backup` a wrapper. The wrapper runs `backup-run`, captures its exit code
and last output line, then POSTs `{status, message, time, size_mb, snapshots}` to an HA
**webhook** (`curl --retry 3`; the URL lives root-only in `/etc/restic/ha-webhook`). HA side:
a webhook-triggered automation (`local_only: true`) writes the payload into
`input_text`/`input_datetime`/`input_number` helpers, and a second automation notifies on a
non-"ok" status, or daily when the last success is more than 26 h old, which catches a job
that never ran. Nothing on the box needs an HA account. Don't put `if run_backup; then` around
a function that relies on `set -e`: bash turns `set -e` off inside an `if` condition, so
failures pass silently. Use a separate script and check its exit code. To test: unmount
the card, run the wrapper, check that the alert arrives, remount, run it again.

A card in the same machine guards against SSD failure, bad updates and mistakes, but not
against theft, fire or the laptop dying with the card inside. Add an off-site copy for data
that really matters.

## Off-box target for Home Assistant's backups (Samba)

HA's automatic backups land only on its own disk by default (on a Pi, the same SD card it
runs on). HA can also write each backup to a network share (Settings → System → Storage →
Add network storage, usage **Backup**, then select it under Backups → locations). Give it a
share that needs a login and serves nothing else:

```bash
sudo apt-get install -y samba
sudo useradd --system --no-create-home --shell /usr/sbin/nologin habackup
sudo install -d -o habackup -g habackup -m 700 /srv/ha-backups
# set its Samba password without echoing it anywhere a transcript can see:
PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
printf '%s\n%s\n' "$PW" "$PW" | sudo smbpasswd -s -a habackup
```

A minimal `/etc/samba/smb.conf` (keep the packaged one as `smb.conf.dist`): `server role =
standalone server`, `server min protocol = SMB2_10`, `smb encrypt = desired`, `map to guest =
never`, `restrict anonymous = 2`, `disable netbios = yes`, `smb ports = 445`, printing off,
and one share with `valid users = habackup`, `browseable = no`, masks 0600/0700. Then
`sudo systemctl disable --now nmbd`. Prove it from Windows (`New-PSDrive … -Credential`,
write and delete a file) and check `sudo smbstatus -b` shows SMB3 with encryption.

- **Exclude the folder from the restic job.** HA backups are encrypted tars, so restic
  can't dedupe them: three ~2.5 GB copies would fill a small backup card within weeks.
  The copy on this disk is already the off-box copy.
- **The encryption key is the backup.** HA encrypts backups by default; without the key
  from its emergency kit, these files can't be restored.
- If a freshly set password is refused from Windows, test it on the box first
  (`smbclient //localhost/<share> -A <credfile>` with the file in `/dev/shm`, deleted
  straight after) to tell a wrong password from a client-side problem.
