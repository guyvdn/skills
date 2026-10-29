---
name: home-lan-dropouts
description: 'Use this skill when a device on a home network keeps disconnecting for a second or two and then recovers — a game console kicked from online matches, a TV or streaming box that stalls, "my PlayStation/Xbox keeps losing connection", intermittent packet loss — and the user wants to know whether the Wi-Fi, a cable, a switch, the router or the internet connection is to blame. Covers finding the device on the LAN, choosing control targets, catching the event with a timestamped multi-target ping watch, the link-up broadcast fingerprint that proves a cable/port flap, PlayStation rest-mode detection, and the false alarms (Google ICMP throttling, clock skew) that point at the wrong culprit. Not for slow-but-stable connections (speed tests) or Wi-Fi coverage planning.'
version: 1.0.0
---

# Brief dropouts on a home LAN

A device that drops for "a second or two" can't be diagnosed by looking at it once. The method
is to **catch an event while it happens, from a wired host, with control targets probed in the
same instant**, then ask what dropped *together*. Each layer between the device and the
internet has a target that only fails if that layer fails.

## Workflow

1. **Find the device.** Ping-sweep the subnet so the ARP table fills, then map MACs to vendors.
   On Linux `/usr/share/ieee-data/oui.txt` (package `ieee-data`) is the OUI database:

   ```bash
   for i in $(seq 1 254); do (ping -c1 -W1 192.168.1.$i >/dev/null &); done; sleep 3
   ip -4 neigh | grep lladdr
   grep -i "^AABBCC" /usr/share/ieee-data/oui.txt   # first 6 hex digits of the MAC, uppercase
   ```

   A MAC whose first byte has bit `0x02` set (`x2`, `x6`, `xA`, `xE`) is randomised: a phone,
   not a fixed device. PlayStations answer the discovery probe below with their type and name,
   which beats guessing between two consoles from the same vendor.

2. **Ask the user how it is connected** (Wi-Fi, cable to the router, cable to a switch or a
   mesh/booster node) and **what else hangs off the same switch or node**. Those neighbours are
   the most valuable controls. Latency already hints: a cabled device reads a flat ~1 ms from a
   wired host, a Wi-Fi one has a 1–3 ms median with a p95 of 20–40 ms.

3. **Pick a wired vantage point** and start the watch with one target per layer:

   | Target | Fails only if… |
   |---|---|
   | the device | anything on its path, or the device itself |
   | other devices on the **same switch** | the switch, its power supply, or its uplink |
   | the router | the router itself, or the vantage point's own link |
   | `1.1.1.1` plus a hop just past the router | the internet connection |

   ```bash
   python scripts/netwatch.py --minutes 30 --log watch.log \
       console=192.168.1.50 tv=192.168.1.51 bridge=192.168.1.52 router=192.168.1.1 \
       cf=1.1.1.1 isp=<first public hop from tracert/traceroute> --ps-state 192.168.1.50
   ```

   Every probe goes to the log; stdout carries only `DOWN`/`UP`/`ps-state` changes, so it can
   feed an event monitor directly. Ask the user to have the device in use (a game running), and
   to note the clock time of any kick.

4. **On a Linux host in the same broadcast domain, capture the device's broadcasts.** This
   tells a link flap apart from everything else (see *The link-up fingerprint*). A Wi-Fi host
   works, since the router bridges broadcasts to Wi-Fi:

   ```bash
   sudo timeout 3600 tcpdump -i <iface> -n -tttt -l -e \
     "ether src <device-mac> and (broadcast or multicast or arp or port 67 or port 68)" > bcast.txt
   ```

5. **Read the result**: `python scripts/summarize.py watch.log --min 2`, and line the runs up
   by timestamp:

   | What dropped together | Cause |
   |---|---|
   | device only, link-up burst in the capture, device still awake | its cable, its switch port, or its network interface |
   | device **and** its switch neighbours | the switch, its power adapter, or the switch→router cable |
   | everything on the LAN, router included | the router (or the vantage point's own link: check a second host) |
   | only internet targets, LAN clean | the internet line or the router's WAN side |
   | device only, `ps-state` went to standby | rest mode, not a fault |

6. **Isolate with one change at a time**, cheapest first, and watch a whole session after
   each: swap the cable into another switch port, then swap the cable, then bypass the switch
   (cable straight into the router for an evening). Two changes at once can't tell which one
   helped.

## The link-up fingerprint

When a network interface comes up from scratch (cable re-seated, port renegotiated, NIC reset)
it announces itself within milliseconds. In the capture this looks like:

```
<mac> > ff:ff:ff:ff:ff:ff  ARP  Request who-has <gateway> tell 0.0.0.0
<mac> > ff:ff:ff:ff:ff:ff  IPv4 0.0.0.0.68 > 255.255.255.255.67: BOOTP/DHCP, Request
<mac> > ff:ff:ff:ff:ff:ff  ARP  Request who-has <its own IP> tell 0.0.0.0     (RFC 5227 probe)
<mac> > ff:ff:ff:ff:ff:ff  ARP  Request who-has <its own IP> tell <its own IP> (announcement)
<mac> > ff:ff:ff:ff:ff:ff  ARP  Request who-has <gateway and recent peers> tell <its own IP>
```

A running device never sends `tell 0.0.0.0` or a DHCP request from `0.0.0.0`. Seeing that burst
at the moment pings were lost, with the device still awake and its switch neighbours clean,
proves the device's own link went down and up. Outside an event the capture shows only
unicast ARP *replies* to the capturing host (answers to its own ARP refreshes while it pings
the device), which is normal.

## Gotchas

- **`8.8.8.8` is not an internet health check.** Google deprioritises ICMP and can drop pings
  in clusters of 1–4 every few minutes, while `1.1.1.1` and the ISP's own servers stay clean. Never
  call the line bad on Google alone; require `1.1.1.1` and a hop past the router to drop too.
- **Some ISP hops never answer echo.** A carrier-grade-NAT hop (`10.x`, `100.64.x`) that shows
  up in `traceroute` may give 100% loss to ping. Pick the next public hop instead. Routers
  also answer pings at low priority, so a few single losses there mean nothing.
- **Rest mode looks exactly like a dropout.** A console entering or leaving rest mode can go
  silent for several seconds (9–17 s seen on a PS5). Poll its power state
  (`--ps-state`), or ask whether it was in use. The user's "a second or two" is the length to
  look for; a 17 s gap is usually something else.
- **One lost probe is noise.** The device, the TV and a smart-home bridge losing a single probe
  in the same instant happens on a healthy LAN. Use `--min-lost 2` (the default) for events.
- **Line logs up only after checking the clocks.** Run `scripts/clock_offset.py` on every host
  whose logs you compare. A Windows PC whose `w32tm /query /status` shows
  `Source: Local CMOS Clock` has never synced and can be a second or more off, enough to put an
  effect before its cause. `w32tm /resync` may answer "no time data was available" and still
  start a sync that lands seconds later: check `Last Successful Sync Time` before retrying.
  Estimating skew by timing `ssh host date` is too coarse: the SSH handshake dominates.
- **A Wi-Fi vantage point adds its own jitter and losses.** Use it as a second witness for
  device events, not as the primary probe; if only the Wi-Fi host saw a drop, it was its own.
- **ISP routers and mesh boosters often expose nothing on the LAN** (no web UI, no SNMP, no
  syslog): only DNS answers. Their logs live in the ISP's app or portal, so don't spend time
  port-scanning for an admin page. The diagnosis has to come from the endpoints.
- **Unmanaged switches have no logs and no settings.** "Green" switches run Energy Efficient
  Ethernet (802.3az) that can't be turned off; some NICs handle it badly and renegotiate the
  link. This is a hypothesis to test by bypassing the switch, not a conclusion from the
  capture alone.

## PlayStation discovery and power state

PS4 and PS5 answer an unauthenticated UDP probe: PS5 on port `9302`, PS4 on `987`.

```
SRCH * HTTP/1.1
device-discovery-protocol-version:00030010
```

The reply's first line is `HTTP/1.1 200 Ok` when awake and `HTTP/1.1 620 Server Standby` in rest
mode; the headers carry `host-type` (`PS4`/`PS5`), `host-name`, `host-id` (its MAC) and
`system-version`. `netwatch.py --ps-state` polls this every 2 s. A single `no-reply` between
two `200 Ok` answers is a lost UDP packet, not a state change.

## Scripts

All are plain Python 3 with no dependencies, need no admin or root, and run on Windows and Linux.

- **`scripts/netwatch.py`**: multi-target ping watch with event output, optional PlayStation
  power-state polling. `--help` for options.
- **`scripts/summarize.py`**: per-target loss and every run of consecutive losses from a
  `netwatch.py` log.
- **`scripts/clock_offset.py`**: this host's clock offset against NTP, before lining logs up.
