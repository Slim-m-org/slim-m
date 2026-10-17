# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Samples a process's CPU and resident memory from /proc while a load run goes.

`sample <pid> <csv>` loops until the process is gone or it is killed;
`summarize <csv>` prints average and peak CPU and RSS over the rows.
"""
import csv
import os
import sys
import time

TICKS = os.sysconf("SC_CLK_TCK")
FIELDS = ["t", "cpu_seconds", "rss_kb", "threads", "fds"]


def read_sample(pid, proc="/proc"):
    """One row, or None when the process has gone."""
    try:
        with open(f"{proc}/{pid}/stat", encoding="utf-8") as handle:
            stat = handle.read()
        # The command name can hold spaces, so split after its closing paren.
        rest = stat[stat.rindex(")") + 2:].split()
        cpu = (int(rest[11]) + int(rest[12])) / TICKS
        rss_kb = int(rest[21]) * os.sysconf("SC_PAGE_SIZE") // 1024
        fds = len(os.listdir(f"{proc}/{pid}/fd"))
        return {"t": time.time(), "cpu_seconds": cpu, "rss_kb": rss_kb,
                "threads": int(rest[17]), "fds": fds}
    except (OSError, ValueError, IndexError):
        return None


def sample(pid, out_path, interval=1.0):
    with open(out_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, FIELDS)
        writer.writeheader()
        while True:
            row = read_sample(pid)
            if row is None:
                return
            writer.writerow(row)
            handle.flush()
            time.sleep(interval)


def summarize(rows):
    """Average CPU is cores-busy over the whole window, so 2.0 means two full cores."""
    if len(rows) < 2:
        return "too few samples"
    wall = rows[-1]["t"] - rows[0]["t"]
    busy = rows[-1]["cpu_seconds"] - rows[0]["cpu_seconds"]
    peak = max(
        (b["cpu_seconds"] - a["cpu_seconds"]) / (b["t"] - a["t"])
        for a, b in zip(rows, rows[1:]) if b["t"] > a["t"])
    return "\n".join([
        f"window            {wall:.1f}s over {len(rows)} samples",
        f"cpu avg           {busy / wall:.2f} cores ({busy:.1f} cpu-seconds)",
        f"cpu peak (1s)     {peak:.2f} cores",
        f"rss start/peak    {rows[0]['rss_kb'] // 1024} / "
        f"{max(r['rss_kb'] for r in rows) // 1024} MiB",
        f"threads peak      {max(r['threads'] for r in rows)}",
        f"open fds peak     {max(r['fds'] for r in rows)}",
    ])


def load_rows(path):
    with open(path, newline="", encoding="utf-8") as handle:
        return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(handle)]


def main(argv):
    if len(argv) == 4 and argv[1] == "sample":
        sample(int(argv[2]), argv[3])
        return 0
    if len(argv) == 3 and argv[1] == "summarize":
        print(summarize(load_rows(argv[2])))
        return 0
    print("usage: load_resource.py sample <pid> <csv> | summarize <csv>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
