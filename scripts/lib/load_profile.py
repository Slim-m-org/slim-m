# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Top frames from a samply profile, so a slow run can be read without a browser.

samply records addresses and, with --unstable-presymbolicate, a sidecar of
symbol tables next to the profile. This joins the two and prints self time,
inclusive time and the busiest threads, which is what the Firefox Profiler's
call tree shows first.
"""
import bisect
import collections
import gzip
import json
import re
import sys

_SEGMENT = re.compile(r"(\d+)")
_ESCAPES = {"$LT$": "<", "$GT$": ">", "$u20$": " ", "$C$": ",", "$RF$": "&",
            "$LP$": "(", "$RP$": ")", "$BP$": "*", "$SP$": "@"}


def demangle(name):
    """Legacy Rust mangling only; anything else comes back unchanged."""
    if not name.startswith("_ZN"):
        return name
    rest, parts = name[3:], []
    while rest and rest[0].isdigit():
        match = _SEGMENT.match(rest)
        size = int(match.group(1))
        start = match.end()
        parts.append(rest[start:start + size])
        rest = rest[start + size:]
    if parts and re.fullmatch(r"h[0-9a-f]{16}", parts[-1]):
        parts.pop()
    text = "::".join(parts)
    for raw, plain in _ESCAPES.items():
        text = text.replace(raw, plain)
    return text.replace("..", "::")


class Symbols:
    """The sidecar's per-library tables, looked up by relative address."""

    def __init__(self, sidecar):
        self.strings = sidecar["string_table"]
        self.libs = {}
        for lib in sidecar["data"]:
            table = sorted(lib["symbol_table"], key=lambda row: row["rva"])
            self.libs[(lib["debug_name"], lib["code_id"])] = (
                [row["rva"] for row in table], table)

    def name(self, lib, address):
        found = self.libs.get((lib["debugName"], lib["codeId"]))
        if found is None:
            return f"{lib['name']}+0x{address:x}"
        rvas, table = found
        index = bisect.bisect_right(rvas, address) - 1
        if index < 0 or address >= table[index]["rva"] + table[index]["size"]:
            return f"{lib['name']}+0x{address:x}"
        return demangle(self.strings[table[index]["symbol"]])


def _frame_names(thread, libs, symbols):
    """One display name per frame row of a thread."""
    frames, funcs, resources = thread["frameTable"], thread["funcTable"], thread["resourceTable"]
    names = []
    for row in range(frames["length"]):
        resource = funcs["resource"][frames["func"][row]]
        lib_index = resources["lib"][resource] if resource is not None and resource >= 0 else None
        if lib_index is None:
            names.append("(unknown)")
        else:
            names.append(symbols.name(libs[lib_index], frames["address"][row]))
    return names


def _first_sample_time(profile, since_epoch_ms):
    """The profile clock reading at `since_epoch_ms`, or None to keep every sample.

    Sample times are a monotonic clock; `meta.startTime` is the wall clock at
    the moment the earliest thread started, so the two line up there.
    """
    if since_epoch_ms is None:
        return None
    origin = min(t["processStartupTime"] for t in profile["threads"] if t["processStartupTime"] > 0)
    return origin + (since_epoch_ms - profile["meta"]["startTime"])


def analyse(profile, symbols, since_epoch_ms=None):
    """Counts per symbol (self, inclusive) and per thread name."""
    selfs, inclusive, threads = collections.Counter(), collections.Counter(), collections.Counter()
    total = 0
    cutoff = _first_sample_time(profile, since_epoch_ms)
    for thread in profile["threads"]:
        names = _frame_names(thread, profile["libs"], symbols)
        stack_frame = thread["stackTable"]["frame"]
        stack_prefix = thread["stackTable"]["prefix"]
        cache = {}
        for stack, when in zip(thread["samples"]["stack"], thread["samples"]["time"]):
            if stack is None or (cutoff is not None and when < cutoff):
                continue
            total += 1
            threads[thread["name"]] += 1
            selfs[names[stack_frame[stack]]] += 1
            if stack not in cache:
                seen, cursor = set(), stack
                while cursor is not None:
                    seen.add(names[stack_frame[cursor]])
                    cursor = stack_prefix[cursor]
                cache[stack] = seen
            inclusive.update(cache[stack])
    return total, selfs, inclusive, threads


def render(total, selfs, inclusive, threads, top):
    def block(title, counter):
        lines = [title]
        for name, count in counter.most_common(top):
            lines.append(f"  {100.0 * count / total:5.1f}%  {name[:150]}")
        return lines
    return "\n".join([
        f"{total} samples", "", *block("busiest threads", threads), "",
        *block("self time", selfs), "", *block("inclusive time", inclusive)])


def main(argv):
    if len(argv) < 2:
        print("usage: load_profile.py <profile.json.gz> [top-n [since-epoch-ms]]", file=sys.stderr)
        return 2
    top = int(argv[2]) if len(argv) > 2 else 25
    since = float(argv[3]) if len(argv) > 3 else None
    with gzip.open(argv[1], "rt", encoding="utf-8") as handle:
        profile = json.load(handle)
    with open(argv[1].removesuffix(".gz") + ".syms.json", encoding="utf-8") as handle:
        symbols = Symbols(json.load(handle))
    print(render(*analyse(profile, symbols, since), top))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
