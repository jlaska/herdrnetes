"""EXP-008 stage B: counter.log continuity over a step window.

usage: python3 -I gaps.py <counter.log> <t0-epoch-ms>

counter.log lines: "<EPOCHREALTIME> <ISO> COUNT n=<N>" or "... ACK <word> pid=.. start=.. nonce=.. n=..".
Reports, for COUNT lines from t0-30 s to the end: lines, first/last n, n resets (n not +1),
the largest inter-sample gap, and every gap > 3 s (the classification threshold).
"""

import re
import sys

COUNT = re.compile(r"^(\d+\.\d+) \S+ COUNT n=(\d+)$")


def main() -> int:
    path, t0 = sys.argv[1], int(sys.argv[2]) / 1000.0
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = COUNT.match(line.strip())
            if m:
                rows.append((float(m.group(1)), int(m.group(2))))
    win = [r for r in rows if t0 == 0 or r[0] >= t0 - 30]
    if not win:
        print("log_lines=0 window_lines=0 verdict=no-data")
        return 1
    resets = [(a, b) for a, b in zip(win, win[1:]) if b[1] != a[1] + 1]
    gaps = [(a[0], b[0] - a[0], a[1], b[1]) for a, b in zip(win, win[1:]) if b[0] - a[0] > 3.0]
    mx = max((b[0] - a[0] for a, b in zip(win, win[1:])), default=0.0)
    print(f"log_lines={len(rows)} window_lines={len(win)} window_first_n={win[0][1]} window_last_n={win[-1][1]}")
    print(f"window_first_t={win[0][0]:.3f} window_last_t={win[-1][0]:.3f} max_gap_s={mx:.3f}")
    print(f"n_discontinuities={len(resets)} gaps_over_3s={len(gaps)}")
    for a, b in resets[:10]:
        print(f"  discontinuity n={a[1]}->{b[1]} at t={b[0]:.3f}")
    for t, d, na, nb in gaps[:10]:
        print(f"  gap {d:.3f}s after t={t:.3f} n={na}->{nb}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
