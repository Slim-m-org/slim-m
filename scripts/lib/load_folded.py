# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Folded stacks from a samply profile, the input `inferno-flamegraph` renders.

Reuses load_profile's symbol join. One line per distinct stack, root first,
frames joined by `;`, then the sample count. Each thread name is the root frame so
the tokio workers, the blocking pool and the rest read as separate towers.
"""
import collections
import gzip
import json
import sys

import load_profile


def fold(profile, symbols, since_epoch_ms=None):
    """A Counter from folded stack text to sample count."""
    folded = collections.Counter()
    cutoff = load_profile._first_sample_time(profile, since_epoch_ms)
    for thread in profile["threads"]:
        names = load_profile._frame_names(thread, profile["libs"], symbols)
        stack_frame = thread["stackTable"]["frame"]
        stack_prefix = thread["stackTable"]["prefix"]
        cache = {}
        for stack, when in zip(thread["samples"]["stack"], thread["samples"]["time"]):
            if stack is None or (cutoff is not None and when < cutoff):
                continue
            if stack not in cache:
                frames, cursor = [], stack
                while cursor is not None:
                    frames.append(names[stack_frame[cursor]].replace(";", ":"))
                    cursor = stack_prefix[cursor]
                cache[stack] = ";".join([thread["name"].replace(";", ":"), *reversed(frames)])
            folded[cache[stack]] += 1
    return folded


def main(argv):
    if len(argv) < 2:
        print("usage: load_folded.py <profile.json.gz> [since-epoch-ms]", file=sys.stderr)
        return 2
    since = float(argv[2]) if len(argv) > 2 else None
    with gzip.open(argv[1], "rt", encoding="utf-8") as handle:
        profile = json.load(handle)
    with open(argv[1].removesuffix(".gz") + ".syms.json", encoding="utf-8") as handle:
        symbols = load_profile.Symbols(json.load(handle))
    for stack, count in fold(profile, symbols, since).items():
        print(f"{stack} {count}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
