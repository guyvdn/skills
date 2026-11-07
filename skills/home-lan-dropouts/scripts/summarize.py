#!/usr/bin/env python3
"""Summarise a netwatch.py log: loss per target and every run of consecutive losses.

  python summarize.py watch.log            # all targets
  python summarize.py watch.log --min 2    # hide single lost probes

Single lost probes are normal background noise; runs of 2+ are the events to explain.
Line runs up across targets by timestamp to see what dropped together.
"""
import argparse, collections


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--min", type=int, default=1, help="shortest run of losses to list")
    a = ap.parse_args()

    by = collections.OrderedDict()
    for line in open(a.log, encoding="utf-8"):
        parts = line.split()
        if len(parts) != 3 or parts[2] not in ("ok", "LOST"):
            continue  # EVENT and ps-state lines
        by.setdefault(parts[1], []).append((parts[0], parts[2]))

    for name, rows in by.items():
        lost = sum(1 for _, v in rows if v == "LOST")
        print(f"{name:12} probes={len(rows):6} lost={lost:5} ({100 * lost / len(rows):.2f}%)")
        run = []
        for ts, v in rows + [("", "ok")]:
            if v == "LOST":
                run.append(ts)
            elif run:
                if len(run) >= a.min:
                    print(f"    {run[0]} .. {run[-1]}  {len(run)} lost")
                run = []


if __name__ == "__main__":
    main()
