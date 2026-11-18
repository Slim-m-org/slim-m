#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Runs packages/app test files many to an isolate through generated bundles.

  client_bundles.py write                         rewrite test/.bundles/
  client_bundles.py deal --shards 12 --index 0    write, then print shard 0's paths
  client_bundles.py run [--concurrency 2]         the whole package, bundled
  client_bundles.py verify [--concurrency 2]      bundled and per-file results must match
  client_bundles.py retry REPORT.json             rerun its failed bundled files alone
  client_bundles.py compare PER_FILE.json BUNDLED.json

A bundle imports one folder's test files with a prefix and runs each main
inside a group named after the file, so a failure still names its file.
Files that cannot share an isolate run alone: see `lone_reason` and
client_bundle_lone.txt. docs/ci-details.md explains the trade.
"""
import argparse
import collections
import os
import re
import subprocess
import sys

import client_shards
import safe_paths
import client_bundle_results as reports
from dart_source import strip_block_comments

HERE = os.path.dirname(os.path.abspath(__file__))
APP_DIR = client_shards.APP_DIR
BUNDLE_DIR = os.path.join("test", ".bundles")
LONE_FILE = os.path.join(HERE, "client_bundle_lone.txt")
# Measured per-file load and boot cost a bundle pays once instead of per file.
FILE_OVERHEAD = 0.7
# Summed test-body seconds per bundle: small enough for the dealer to balance.
CHUNK_SECONDS = 30.0

# State no teardown undoes: files that set it share bundles only with files that set it too.
_STICKY_STATE = (
    (re.compile(r"\b(loadRealFonts|loadFontFamily|loadEmojiFont|FontLoader)\b"), "fonts"),
    (re.compile(r"\b(PackageInfo\.setMockInitialValues|mockAppVersion)\b"), "appinfo"),
)
_PLAIN_MAIN = re.compile(r"^void\s+main\s*\(\s*\)\s*(\{|=>)", re.M)
_STATIC_RULES = (
    (re.compile(r"\btearDownAll\s*\("), "tearDownAll runs at its group's end"),
    (re.compile(r"\bmatchesGoldenFile\b"), "golden output"),
    (re.compile(r"\b(Http|IO)Overrides\.global\s*="), "sets process-wide overrides"),
    (re.compile(r"\bDirectory\.current\s*="), "changes the working directory"),
    (re.compile(r"\bPlatform\.script\b"), "reads its own script path"),
    (re.compile(r"\b(HttpServer|ServerSocket)\.bind\w*\s*\(|\bWebSocket\.connect\s*\("),
     "real loopback network, which an earlier file's test binding answers with HTTP 400"),
    (re.compile(r"\b(Live|Automated|IntegrationTest)\w*Binding\b"), "custom test binding"),
    (re.compile(r"^@(TestOn|Timeout|Skip|Tags|OnPlatform|Retry)\b", re.M),
     "a library-level test annotation, which only an entrypoint's own library carries"),
)


def load_lone(path=LONE_FILE):
    """{test file: reason} from the committed list of files proven to leak."""
    lone = {}
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return lone
    for line in lines:
        entry, _, reason = line.partition("#")
        entry = entry.strip()
        if entry:
            lone[entry] = reason.strip() or "listed"
    return lone


def lone_reason(rel_path, source, lone=None):
    """Why [rel_path] must run in its own isolate, or None when it can share one."""
    if lone and rel_path in lone:
        return lone[rel_path]
    if rel_path.startswith("test/snapshots/") or "/ui_snapshot" in rel_path:
        return "the snapshot matrix, which capture mode runs per file"
    code = strip_block_comments(source, blank_strings=True)
    if not _PLAIN_MAIN.search(code):
        return "main is not a plain synchronous void main()"
    for pattern, reason in _STATIC_RULES:
        if pattern.search(code):
            return reason
    return None


def folder_key(rel_path):
    """The folder a test file is bundled with: test/features/<x>, test/<dir> or test."""
    parts = rel_path.split("/")
    if len(parts) > 3 and parts[1] == "features":
        return "/".join(parts[:3])
    if len(parts) > 2:
        return "/".join(parts[:2])
    return "test"


def bundle_key(rel_path, source):
    """The bundle name stem for a file that can share an isolate, e.g. features_voice_fonts.

    Real fonts stay loaded and change text metrics; PackageInfo's mock values stay set.
    """
    folder = folder_key(rel_path)
    slug = "root" if folder == "test" else folder.replace("/", "_").removeprefix("test_")
    return "_".join([slug] + sticky_kinds(source))


def sticky_kinds(source):
    """The kinds of state [source] sets that no teardown undoes, e.g. ["fonts"]."""
    code = strip_block_comments(source, blank_strings=True)
    return [kind for pattern, kind in _STICKY_STATE if pattern.search(code)]


def body_seconds(path, durations):
    return max(durations.get(path, client_shards.UNKNOWN_SECONDS) - FILE_OVERHEAD, 0.05)


def chunk(files, durations, limit=CHUNK_SECONDS):
    """[files] (sorted) cut into consecutive runs of about [limit] body seconds each."""
    total = sum(body_seconds(f, durations) for f in files)
    count = max(1, round(total / limit))
    target = total / count
    chunks, current, spent = [], [], 0.0
    for f in files:
        current.append(f)
        spent += body_seconds(f, durations)
        if spent >= target * (len(chunks) + 1) and len(chunks) < count - 1:
            chunks.append(current)
            current = []
    if current:
        chunks.append(current)
    return chunks


def plan(app_dir=APP_DIR, durations=None, lone=None):
    """({bundle name: [files]}, {lone file: reason}) for every app test file."""
    durations = client_shards.load_durations() if durations is None else durations
    lone = load_lone() if lone is None else lone
    by_key, alone = collections.defaultdict(list), {}
    for rel in client_shards.test_files(app_dir):
        with open(os.path.join(app_dir, rel), encoding="utf-8") as fh:
            source = fh.read()
        reason = lone_reason(rel, source, lone)
        if reason:
            alone[rel] = reason
        else:
            by_key[bundle_key(rel, source)].append(rel)
    bundles = {}
    for key, files in sorted(by_key.items()):
        for i, part in enumerate(chunk(files, durations)):
            bundles[f"{BUNDLE_DIR}/{key}_{i}.dart".replace(os.sep, "/")] = part
    return bundles, alone


def bundle_source(files, framework="package:flutter_test/flutter_test.dart"):
    """The Dart entrypoint that runs [files] (paths under test/) in one isolate."""
    lines = [
        "// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0",
        "// Generated by scripts/lib/client_bundles.py; do not edit.",
        f"import '{framework}';",
        "",
    ]
    for i, f in enumerate(files):
        if not re.fullmatch(r"test/[\w./-]+_test\.dart", f):
            raise ValueError(f"cannot bundle {f!r}")
        lines.append(f"import '../{f[len('test/'):]}' as t{i};")
    lines += ["", "void main() {"]
    lines += [f"  group('{f}', t{i}.main);" for i, f in enumerate(files)]
    lines += ["}", ""]
    return "\n".join(lines)


def write(app_dir=APP_DIR, durations=None, lone=None):
    """Writes every bundle, removes stale ones, returns plan()'s result."""
    bundles, alone = plan(app_dir, durations, lone)
    out_dir = os.path.join(app_dir, BUNDLE_DIR)
    os.makedirs(out_dir, exist_ok=True)
    keep = {os.path.basename(name) for name in bundles}
    for name in os.listdir(out_dir):
        if name.endswith(".dart") and name not in keep:
            os.remove(os.path.join(out_dir, name))
    for name, files in bundles.items():
        path = os.path.join(app_dir, name)
        text = bundle_source(files)
        try:
            with open(path, encoding="utf-8") as fh:
                if fh.read() == text:
                    continue
        except OSError:
            pass
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
    return bundles, alone


def unit_costs(bundles, alone, durations):
    """{path flutter test runs: predicted seconds} for the dealer."""
    costs = {f: durations.get(f, client_shards.UNKNOWN_SECONDS) for f in alone}
    for name, files in bundles.items():
        costs[name] = FILE_OVERHEAD + sum(body_seconds(f, durations) for f in files)
    return costs


def per_file_mode():
    """SLIMM_TEST_PER_FILE=1 gives every file its own isolate again, as before bundles."""
    return os.environ.get("SLIMM_TEST_PER_FILE") == "1"


def units(app_dir=APP_DIR, durations=None, shards=1, index=0):
    """Writes the bundles and returns shard [index]'s paths, costliest first."""
    durations = client_shards.load_durations() if durations is None else durations
    if per_file_mode():
        return client_shards.deal(client_shards.test_files(app_dir), shards, durations)[0][index]
    bundles, alone = write(app_dir, durations)
    costs = unit_costs(bundles, alone, durations)
    dealt, _ = client_shards.deal(sorted(costs), shards, costs)
    return sorted(dealt[index], key=lambda p: (-costs[p], p))


def _checked_paths(paths, app_dir):
    """Test paths only: a Dart file inside [app_dir], never something flutter could read as an option."""
    root = os.path.realpath(app_dir)
    checked = []
    for path in paths:
        full = os.path.realpath(os.path.join(app_dir, path))
        if path.startswith("-") or not path.endswith(".dart") or not full.startswith(root + os.sep):
            raise ValueError(f"not a test file under {app_dir}: {path!r}")
        checked.append(path)
    return checked


def _checked_args(args):
    """Flags only: each one an option, so no stray value turns into a path or a command."""
    for arg in args:
        if not arg.startswith("-"):
            raise ValueError(f"flutter test arguments must be options: {arg!r}")
    return list(args)


def flutter_test(paths, args, out_path=None, app_dir=APP_DIR):
    """Runs `flutter test [args] [paths]`, into [out_path] when given (stderr too)."""
    cmd = ["flutter", "test", *_checked_args(args), *_checked_paths(paths, app_dir)]
    if out_path is None:
        return subprocess.run(cmd, cwd=app_dir, check=False).returncode
    with open(out_path, "w", encoding="utf-8") as fh:
        return subprocess.run(cmd, cwd=app_dir, stdout=fh, stderr=subprocess.STDOUT,
                              check=False).returncode


def verify(only, concurrency, out_dir):
    """Runs the bundles named by [only] (all when empty), then their files one by one."""
    bundles, _ = write()
    chosen = {n: fs for n, fs in bundles.items() if not only or any(o in n for o in only)}
    os.makedirs(out_dir, exist_ok=True)
    args = [f"--concurrency={concurrency}", "--reporter=json"]
    bundled_json = os.path.join(out_dir, "bundled.json")
    per_file_json = os.path.join(out_dir, "per-file.json")
    flutter_test(sorted(chosen), args, bundled_json)
    flutter_test(sorted(f for fs in chosen.values() for f in fs), args, per_file_json)
    return reports.report(_read(per_file_json), _read(bundled_json), chosen)


def retry(report_path, concurrency, out_dir):
    """Reruns each bundled file that failed in [report_path] alone; 0 when all pass alone."""
    os.makedirs(out_dir, exist_ok=True)
    rerun_json = os.path.join(out_dir, "retry.json")

    def rerun(files):
        flutter_test(files, [f"--concurrency={concurrency}", f"--file-reporter=json:{rerun_json}"])
        return _read(rerun_json)

    return retry_alone(_read(report_path), plan()[0], rerun, "client/packages/app/", LONE_FILE)


def retry_alone(lines, bundles, rerun, where, lone_file, emit=print):
    """Reruns through [rerun] each bundled file that failed in [lines]; 0 when all pass alone.

    A file that fails only when bundled is a leak between files, not a broken test.
    """
    bundles = {n: fs for n, fs in bundles.items() if n in reports.suite_paths(lines)}
    members = {f for fs in bundles.values() for f in fs}
    failed = reports.failed_files(reports.results(lines, bundles))
    bundled, alone = sorted(failed & members), sorted(failed - members)
    for f in alone:
        emit(f"::error file={where}{f}::failed running on its own")
    if alone or not bundled:
        return 1
    rerun_results = reports.results(rerun(bundled), {})
    broken = [f for f in bundled if f in reports.failed_files(rerun_results) or f not in rerun_results]
    hint = os.path.relpath(lone_file, client_shards.REPO)
    for f in bundled:
        if f in broken:
            emit(f"::error file={where}{f}::fails on its own too")
        else:
            emit(f"::warning file={where}{f}::failed only when bundled, so an "
                  f"earlier file leaks state into it; list it in {hint}")
    return 1 if broken else 0


def run(concurrency, extra, out_dir):
    """The whole app package bundled, then retry() on a failure, as client-ci's shards do."""
    os.makedirs(out_dir, exist_ok=True)
    report = os.path.join(out_dir, "run.json")
    args = [f"--concurrency={concurrency}", f"--file-reporter=json:{report}", *extra]
    if flutter_test(units(), args) == 0:
        return 0
    return retry(report, concurrency, out_dir)


def _read(path):
    with open(safe_paths.home_or_cwd(path), encoding="utf-8") as fh:
        return fh.read().splitlines()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("write")
    dealer = sub.add_parser("deal")
    dealer.add_argument("--shards", type=int, required=True)
    dealer.add_argument("--index", type=int, required=True)
    runner = sub.add_parser("run", help="extra arguments go to flutter test")
    runner.add_argument("--concurrency", type=int, default=2)
    runner.add_argument("--out", default=os.path.join(APP_DIR, "build", "bundles"))
    checker = sub.add_parser("verify")
    checker.add_argument("--concurrency", type=int, default=2)
    checker.add_argument("--out", default=os.path.join(APP_DIR, "build", "bundles"))
    checker.add_argument("only", nargs="*", help="bundle name parts, e.g. features_sync")
    retrier = sub.add_parser("retry", help="rerun a report's failed bundled files alone")
    retrier.add_argument("report_json")
    retrier.add_argument("--concurrency", type=int, default=2)
    retrier.add_argument("--out", default=os.path.join(APP_DIR, "build", "bundles"))
    comparer = sub.add_parser("compare")
    comparer.add_argument("per_file_json")
    comparer.add_argument("bundled_json")
    args, extra = parser.parse_known_args(argv)
    if extra and args.cmd != "run":
        parser.error(f"unrecognized arguments: {' '.join(extra)}")
    if args.cmd == "write":
        bundles, alone = write()
        bundled = sum(len(f) for f in bundles.values())
        print(f"{len(bundles)} bundles hold {bundled} files; {len(alone)} files run alone")
        return 0
    if args.cmd == "deal":
        if not 0 <= args.index < args.shards:
            parser.error("--index must be in [0, --shards)")
        print("\n".join(units(shards=args.shards, index=args.index)))
        return 0
    if args.cmd == "run":
        return run(args.concurrency, extra, args.out)
    if args.cmd == "retry":
        return retry(args.report_json, args.concurrency, args.out)
    if args.cmd == "verify":
        return 1 if verify(args.only, args.concurrency, args.out) else 0
    bundles, _ = plan()
    return 1 if reports.report(_read(args.per_file_json), _read(args.bundled_json), bundles) else 0


if __name__ == "__main__":
    sys.exit(main())
