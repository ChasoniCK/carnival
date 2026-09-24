#!/usr/bin/env python3
"""Formats what tools/bench/run.sh collected as Markdown.  usage: report.py DIR IDLE OPEN"""
import re
import sys

out, idle_s, open_s = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])


def kv(line):
    return dict(p.split("=", 1) for p in line.split() if "=" in p)


def snapshot(path):
    rows = {}
    try:
        for line in open(path):
            d = kv(line)
            if "pid" in d:
                rows[d.pop("pid")] = d
    except FileNotFoundError:
        pass
    return rows


def names(path):
    try:
        return [line.split() for line in open(path) if line.strip()]
    except FileNotFoundError:
        return []


# rusage counts Mach ticks on Apple silicon (41.67 ns each): believe whichever reading of
# probe's 300 ms self-test comes out at one second of CPU per second of wall time
check = kv(open(f"{out}/selfcheck.txt").read())
raw, scaled = float(check["raw_ratio"]), float(check["scaled_ratio"])
tick = float(check["numer"]) / float(check["denom"]) if abs(scaled - 1) < abs(raw - 1) else 1.0

TIMES = {"user", "sys", "user_p", "sys_p", "qos_def", "qos_mnt", "qos_bg", "qos_ut", "qos_leg", "qos_in", "qos_ui"}
LEVELS = {"footprint", "peak_footprint", "threads"}


def delta(a, b):
    if not a or not b or "error" in a or "error" in b:
        return None
    d = {}
    for k, v in b.items():
        if k in LEVELS:
            d[k] = float(v)
        elif k in a:
            d[k] = (float(v) - float(a[k])) * (tick if k in TIMES else 1)
    d["cpu"] = d["user"] + d["sys"]
    return d


def value(f, d):
    try:
        return f(d) if d else None
    except (KeyError, ZeroDivisionError):
        return None


def table(cols, rows):
    """One row per metric, one column per build; a column holding several runs shows their
    mean and range. Rows that are zero everywhere (energy, instructions in a VM) are left out."""
    print("| | " + " | ".join(n for n, _ in cols) + " |")
    print("|---|" + "---:|" * len(cols))
    for label, f, fmt in rows:
        cells, nonzero = [], False
        for _, ds in cols:
            vs = [v for v in (value(f, d) for d in ds) if v is not None]
            nonzero |= any(vs)
            if not vs:
                cells.append("n/a")
            elif len(vs) == 1:
                cells.append(fmt.format(vs[0]))
            else:
                m = sum(vs) / len(vs)
                cells.append(f"{fmt.format(m)} ({fmt.format(min(vs))}–{fmt.format(max(vs))})")
        if nonzero:
            print(f"| {label} | " + " | ".join(cells) + " |")
    print()


def grouped(pairs):
    """[(name, d)] -> [(group, [d...])], `before2` and `before.3` counting as `before`."""
    groups = {}
    for n, d in pairs:
        groups.setdefault(re.sub(r"[.\d]+$", "", n), []).append(d)
    return list(groups.items())


MB = 2**20
per_h = 3600 / idle_s
ticks = idle_s / 10

print("## carnival bench\n")
print("```")
print(open(f"{out}/env.txt").read().strip())
print(f"idle phase {idle_s:.0f} s, open phase {open_s:.0f} s, rusage tick {tick:.4f} ns "
      f"(self-test raw {raw:.3f}, scaled {scaled:.3f})")
print("```\n")

IDLE_ROWS = [
    ("CPU time, ms per hour", lambda d: d["cpu"] / 1e6 * per_h, "{:.0f}"),
    ("CPU, % of one core", lambda d: d["cpu"] / (idle_s * 1e9) * 100, "{:.4f}"),
    ("CPU per 10 s, µs", lambda d: d["cpu"] / 1e3 / ticks, "{:.0f}"),
    ("...at QoS user-interactive, µs", lambda d: d["qos_ui"] / 1e3 / ticks, "{:.0f}"),
    ("...at QoS user-initiated, µs", lambda d: d["qos_in"] / 1e3 / ticks, "{:.0f}"),
    ("...at QoS default, µs", lambda d: d["qos_def"] / 1e3 / ticks, "{:.0f}"),
    ("...at QoS utility, µs", lambda d: d["qos_ut"] / 1e3 / ticks, "{:.0f}"),
    ("...at QoS background, µs", lambda d: d["qos_bg"] / 1e3 / ticks, "{:.0f}"),
    ("...on P-cores, %", lambda d: (d["user_p"] + d["sys_p"]) / d["cpu"] * 100, "{:.0f}"),
    ("Timer wakeups per hour", lambda d: d["intr_wkups"] * per_h, "{:.0f}"),
    ("Package-idle wakeups per hour", lambda d: d["idle_wkups"] * per_h, "{:.0f}"),
    ("Context switches per hour", lambda d: d["csw"] * per_h, "{:.0f}"),
    ("Mach traps per hour", lambda d: d["mach_sc"] * per_h, "{:.0f}"),
    ("BSD syscalls per hour", lambda d: d["unix_sc"] * per_h, "{:.0f}"),
    ("Mach messages sent per hour", lambda d: d["msgs_sent"] * per_h, "{:.0f}"),
    ("Page faults per hour", lambda d: d["faults"] * per_h, "{:.0f}"),
    ("Energy, mJ per hour", lambda d: d["energy_nj"] / 1e6 * per_h, "{:.2f}"),
    ("Instructions per hour, millions", lambda d: d["instructions"] / 1e6 * per_h, "{:.2f}"),
    ("Memory footprint, MB", lambda d: d["footprint"] / MB, "{:.2f}"),
    ("Peak footprint, MB", lambda d: d["peak_footprint"] / MB, "{:.2f}"),
    ("Threads", lambda d: d["threads"], "{:.0f}"),
]

i0, i1 = snapshot(f"{out}/idle0.txt"), snapshot(f"{out}/idle1.txt")
idle = [(n, delta(i0.get(p), i1.get(p))) for n, p in names(f"{out}/idle.names")]
print(f"### Idle, menu closed: every build side by side for {idle_s:.0f} s\n")
print("Mean of the copies, with their range.\n")
table(grouped(idle), IDLE_ROWS)
print("<details><summary>Each process</summary>\n")
table([(n, [d]) for n, d in idle], IDLE_ROWS)
print("</details>\n")

opened = []
for r, p in names(f"{out}/open.names"):
    o0, o1 = snapshot(f"{out}/open0.{r}.txt").get(p), snapshot(f"{out}/open1.{r}.txt").get(p)
    closed = snapshot(f"{out}/closed.{r}.txt").get(p)
    d = delta(o0, o1)
    if d and closed and "error" not in closed:
        d["after_footprint"] = float(closed["footprint"])
        d["after_peak"] = float(closed["peak_footprint"])
    try:
        if d:
            d["draws"] = float(open(f"{out}/draws.{r}.txt").read())
    except (FileNotFoundError, ValueError):
        pass
    opened.append((r, d))
print(f"### Menu open for {open_s:.0f} s, one build at a time\n")
print("Mean of the runs, with their range.\n")
table(grouped(opened), [
    ("CPU, % of one core", lambda d: d["cpu"] / (open_s * 1e9) * 100, "{:.3f}"),
    ("Panel redraws per minute", lambda d: d["draws"] / (open_s + 10) * 60, "{:.1f}"),
    ("Timer wakeups per second", lambda d: d["intr_wkups"] / open_s, "{:.2f}"),
    ("Context switches per second", lambda d: d["csw"] / open_s, "{:.1f}"),
    ("Mach traps per second", lambda d: d["mach_sc"] / open_s, "{:.1f}"),
    ("BSD syscalls per second", lambda d: d["unix_sc"] / open_s, "{:.1f}"),
    ("Energy, mJ per minute", lambda d: d["energy_nj"] / 1e6 / open_s * 60, "{:.2f}"),
    ("Footprint while open, MB", lambda d: d["footprint"] / MB, "{:.2f}"),
    ("Footprint 35 s after closing, MB", lambda d: d["after_footprint"] / MB, "{:.2f}"),
    ("Peak footprint, MB", lambda d: d["after_peak"] / MB, "{:.2f}"),
])

print("### One sample, in isolation\n")
hot, cold, order = {}, {}, []
try:
    for line in open(f"{out}/micro.txt"):
        f = line.rstrip("\n").split("\t")
        if f[0] == "hot":
            hot[(f[1], f[2])] = (float(f[3]), float(f[4]), float(f[5]))
            if f[2] not in order:
                order.append(f[2])
        elif f[0] == "cold":
            cold[(f[1], f[2])] = (float(f[3]), float(f[4]))
except FileNotFoundError:
    pass
print("| | before, µs | before, syscalls | after, µs | after, syscalls |")
print("|---|---:|---:|---:|---:|")
for b in order:
    cells = []
    for side in ("before", "after"):
        h = hot.get((side, b))
        cells += [f"{h[0]:.2f}", f"{h[1] + h[2]:.0f} ({h[1]:.0f} Mach + {h[2]:.0f} BSD)"] if h else ["-", "-"]
    print(f"| {b}, back to back | " + " | ".join(cells) + " |")
for b in sorted({k[1] for k in cold}):
    cells = []
    for side in ("before", "after"):
        c = cold.get((side, b))
        cells += [f"{c[0]:.0f} (p90 {c[1]:.0f})", ""] if c else ["-", ""]
    print(f"| {b}, once a second (median) | " + " | ".join(cells) + " |")
print()
