# Hardware & power

Part of the [ubuntu-home-server](../SKILL.md) skill. Placeholders (`<USER>`, `<SERVER_IP>`, …) are
listed there; the real values are in the private global `CLAUDE.md`.

Laptop-as-server settings: lid, power loss, battery wear, GPU driver, disk size.

## Keep running with the lid closed

Out of the box, logind **suspends on lid close**, and the server drops off the LAN ("Destination
host unreachable"). Open the lid (or press power) to wake it. Then, as root (plain `sudo` once
the box is key-only, otherwise via the paramiko pattern in [rebuild.md](rebuild.md) §4):

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

## Power back on after an outage

If a long power cut drains the battery, the laptop stays off when power returns. On
ThinkPads the BIOS option is **"Power On with AC Attach"**, and you can set it from Linux
without visiting the BIOS (as long as there's no BIOS admin password):

```bash
d=/sys/class/firmware-attributes/thinklmi/attributes
sudo cat $d/OnByAcAttach/current_value            # Disable
echo Enable | sudo tee $d/OnByAcAttach/current_value
cat $d/pending_reboot                             # 1 → applies at next boot
```

Reboot once, then confirm that it still reads `Enable` and `pending_reboot` is back to `0`.
`ls $d` lists every other BIOS setting (Wake-on-LAN, boot order, Secure Boot …).

## Don't keep the battery at 100%

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

## NVIDIA driver on a Secure Boot laptop

`sudo ubuntu-drivers install --gpgpu` installs the headless `*-server-open` driver. Its
kernel modules come prebuilt and signed by Canonical (`linux-modules-nvidia-*`), so you don't
have to enroll a MOK key at the console. Then install `nvidia-utils-<ver>-server` to get
`nvidia-smi`. The modules may target a **newer kernel** that apt pulled in at the same
time. That's fine: reboot into it. `sudo systemctl reboot` over SSH can take ~30 s to
actually go down, so check `uptime -s` afterwards instead of trusting that SSH answered.

## Disk: use the whole SSD

The Ubuntu Server installer's LVM layout gives the root volume only ~100 GB and leaves the
rest of the volume group unallocated. Before deploying anything, grow it while the box is
running: `sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv` (`-r` also grows the
ext4 filesystem).
