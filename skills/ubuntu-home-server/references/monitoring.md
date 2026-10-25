# Monitoring

Part of the [ubuntu-home-server](../SKILL.md) skill. Placeholders (`<USER>`, `<SERVER_IP>`, …) are
listed there; the real values are in the private global `CLAUDE.md`.

Beszel as the dashboard on the box, Glances as the feed into Home Assistant.

## Beszel (monitoring dashboard)

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

For remote monitoring, publish the hub on its own Tailscale Serve port (see "More apps on
the same name" in [remote-access.md](remote-access.md)), e.g. `sudo tailscale serve --bg --https=8444
http://127.0.0.1:8090`. The hub binds `0.0.0.0`, so its own port 8090 is taken on the
tailnet IP too and plain `http://<tailnet-name>:8090` already works; the Serve port adds
HTTPS, which lets the phone install the dashboard as an app. Check `/api/health` through it.

## Glances → Home Assistant

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
battery, the NVIDIA GPU (via `python3-pynvml`) and, once Docker runs, three Docker totals.
The API has no authentication, so it stays LAN-only.

What to expect after setup:

- **No per-container sensors.** HA's Glances integration creates only aggregates:
  `containers_active` (count), `containers_cpu_usage` and `containers_memory_used`. Per-container
  CPU and memory are only available from `/api/4/containers` or in Beszel.
- **New entities appear only after a reload.** The sensor platform builds its entity list at
  setup, so a newly mounted disk, a new network interface or Docker's first container stays
  invisible until you reload the config entry (`homeassistant.reload_config_entry` with its
  `entry_id`).
- **Rename the device once and new entities follow.** The first batch gets IDs based on the IP
  address (`sensor.192_168_…`) because the device is named after the host. Rename the device to
  the box's hostname and rename those entities (WS `config/entity_registry/update` with
  `new_entity_id`). Glances entities use `has_entity_name`, so everything added later already
  gets IDs based on the hostname.
- **Docker adds churn to network sensors.** Every bridge (`br-<id>`) and container interface
  (`veth<id>`) becomes an RX/TX sensor pair. The `veth` name changes each time a container is
  recreated, so each redeploy leaves those sensors `unavailable`. Delete or ignore them, or hide
  the interfaces in Glances' config.
