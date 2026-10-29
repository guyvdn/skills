#!/usr/bin/env python3
"""Ping several hosts at once and report outages as they happen.

Every probe goes to a log file; only state changes go to stdout, so the output
can feed an agent's event monitor without flooding it.

  python netwatch.py --minutes 30 --log watch.log \
      console=192.168.1.50 tv=192.168.1.51 router=192.168.1.1 cf=1.1.1.1 \
      --ps-state 192.168.1.50

Targets are name=address pairs. --ps-state polls a PlayStation's discovery port
every 2 s, so a rest-mode transition is not mistaken for a dropout.
Works on Windows and Linux (uses the system ping; no admin or root needed).
"""
import argparse, datetime, os, socket, subprocess, sys, threading, time

IS_WIN = os.name == "nt"
lock = threading.Lock()


def stamp():
    return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]


def ping_once(addr, timeout_ms):
    cmd = (["ping", "-n", "1", "-w", str(timeout_ms), addr] if IS_WIN
           else ["ping", "-c", "1", "-W", str(max(1, round(timeout_ms / 1000))), addr])
    out = subprocess.run(cmd, capture_output=True, text=True).stdout.lower()
    # "Destination host unreachable" replies count as lost: they carry no TTL.
    return "ttl=" in out


def ps_state(addr):
    """Status line of a PS4/PS5 discovery reply: '200 Ok' awake, '620 Server Standby' rest mode."""
    msg = b"SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n"
    for port in (9302, 987):  # PS5, PS4
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1.5)
        try:
            s.sendto(msg, (addr, port))
            return s.recvfrom(2048)[0].decode(errors="replace").splitlines()[0].replace("HTTP/1.1 ", "")
        except OSError:
            continue
        finally:
            s.close()
    return "no-reply"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("targets", nargs="+", help="name=address pairs")
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--log", required=True, help="per-probe log (appended)")
    ap.add_argument("--interval", type=float, default=0.5, help="seconds between probes per target")
    ap.add_argument("--timeout-ms", type=int, default=800)
    ap.add_argument("--min-lost", type=int, default=2, help="consecutive losses that count as an outage")
    ap.add_argument("--ps-state", metavar="ADDR", help="also poll this PlayStation's power state")
    a = ap.parse_args()

    targets = []
    for t in a.targets:
        if "=" not in t:
            sys.exit(f"target '{t}' is not name=address")
        targets.append(tuple(t.split("=", 1)))
    end = time.time() + a.minutes * 60
    log = open(a.log, "a", buffering=1, encoding="utf-8")

    def write(line):
        with lock:
            log.write(f"{stamp()} {line}\n")

    def emit(line):
        with lock:
            print(f"{stamp()} {line}", flush=True)
            log.write(f"{stamp()} EVENT {line}\n")

    def pinger(name, addr):
        down_since, lost = None, 0
        while time.time() < end:
            t0 = time.time()
            ok = ping_once(addr, a.timeout_ms)
            write(f"{name} {'ok' if ok else 'LOST'}")
            if not ok:
                lost += 1
                down_since = down_since or t0
                if lost == a.min_lost:
                    emit(f"{name} DOWN since {datetime.datetime.fromtimestamp(down_since):%H:%M:%S.%f}"[:-3])
            else:
                if lost >= a.min_lost:
                    emit(f"{name} UP after {time.time() - down_since:.1f}s ({lost} lost)")
                down_since, lost = None, 0
            time.sleep(max(0, a.interval - (time.time() - t0)))

    def state_poller(addr):
        last = None
        while time.time() < end:
            st = ps_state(addr)
            write(f"ps-state {st}")
            if st != last:
                emit(f"ps-state {st}")
                last = st
            time.sleep(2)

    threads = [threading.Thread(target=pinger, args=t) for t in targets]
    if a.ps_state:
        threads.append(threading.Thread(target=state_poller, args=(a.ps_state,)))
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    emit("watch window ended")


if __name__ == "__main__":
    main()
