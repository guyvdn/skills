#!/usr/bin/env python3
"""Print this machine's clock offset against NTP servers (SNTP, no admin needed).

Run it on every host whose logs you are about to line up. Offsets of a second or
more make a cause and its effect appear in the wrong order.

  python clock_offset.py                     # pool.ntp.org and time.windows.com
  python clock_offset.py time.cloudflare.com
"""
import socket, struct, sys, time

NTP_EPOCH = 2208988800


def offset(host):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        t0 = time.time()
        s.sendto(b"\x1b" + 47 * b"\0", (host, 123))
        d = s.recvfrom(48)[0]
        t1 = time.time()
    finally:
        s.close()
    server = struct.unpack("!I", d[40:44])[0] - NTP_EPOCH + struct.unpack("!I", d[44:48])[0] / 2**32
    return (t0 + t1) / 2 - server  # positive = this clock runs ahead


for host in sys.argv[1:] or ["pool.ntp.org", "time.windows.com"]:
    try:
        print(f"{host:22} local clock {offset(host):+.3f}s")
    except OSError as e:
        print(f"{host:22} unreachable ({e.__class__.__name__})")
