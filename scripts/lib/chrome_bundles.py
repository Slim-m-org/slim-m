#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Runs the files in client/chrome-tests.txt under Chrome, many files to a page.

  chrome_bundles.py run [--jobs 3]   bundle, run, then rerun a failed bundled file alone
  chrome_bundles.py plan             print what each package runs

`flutter test --platform chrome` compiles every file it is given once, then
loads each file in a page of its own, one page at a time: about six seconds a
file on a runner. A bundle is one page for a package's files, so that cost is
paid once. Files that cannot share a page run alone (client_bundles.lone_reason
and chrome_bundle_lone.txt). docs/ci-details.md explains the trade.
"""
import argparse
import collections
import concurrent.futures
import os
import re
import sys
import time

import client_bundles
import client_shards

HERE = os.path.dirname(os.path.abspath(__file__))
CLIENT = os.path.join(client_shards.REPO, "client")
PACKAGES = os.path.join(CLIENT, "packages")
LIST = os.path.join(CLIENT, "chrome-tests.txt")
LONE_FILE = os.path.join(HERE, "chrome_bundle_lone.txt")
BUNDLE_DIR = os.path.join("test", ".chrome_bundles")
_FLUTTER_TEST_DEP = re.compile(r"^\s+flutter_test:", re.M)


def entries(path=LIST):
    """Every listed file, as <package>/test/<path>, in list order."""
    with open(path, encoding="utf-8") as fh:
        return [line.strip() for line in fh if line.strip()]


def by_package(listed):
    """{package: [test/... paths]} in package order."""
    grouped = collections.defaultdict(list)
    for entry in listed:
        package, _, rel = entry.partition("/")
        grouped[package].append(rel)
    return dict(sorted(grouped.items()))


def framework(package_dir):
    """The test library a bundle imports: flutter_test where the package has it, else test."""
    with open(os.path.join(package_dir, "pubspec.yaml"), encoding="utf-8") as fh:
        pubspec = fh.read()
    if _FLUTTER_TEST_DEP.search(pubspec):
        return "package:flutter_test/flutter_test.dart"
    return "package:test/test.dart"


def plan(package_dir, files, lone=None):
    """({bundle path: [files]}, {lone file: reason}) for one package's listed [files]."""
    lone = client_bundles.load_lone(LONE_FILE) if lone is None else lone
    package = os.path.basename(os.path.normpath(package_dir))
    lone = {path.partition("/")[2]: why for path, why in lone.items() if path.startswith(package + "/")}
    by_kind, alone = collections.defaultdict(list), {}
    for rel in files:
        with open(os.path.join(package_dir, rel), encoding="utf-8") as fh:
            source = fh.read()
        reason = client_bundles.lone_reason(rel, source, lone)
        if reason:
            alone[rel] = reason
        else:
            by_kind["_".join(["all"] + client_bundles.sticky_kinds(source))].append(rel)
    bundles = {f"{BUNDLE_DIR}/{kind}.dart".replace(os.sep, "/"): sorted(fs)
               for kind, fs in sorted(by_kind.items())}
    return bundles, alone


def write(package_dir, files, lone=None):
    """Writes [package_dir]'s bundles, removes stale ones, returns plan()'s result."""
    bundles, alone = plan(package_dir, files, lone)
    out_dir = os.path.join(package_dir, BUNDLE_DIR)
    os.makedirs(out_dir, exist_ok=True)
    keep = {os.path.basename(name) for name in bundles}
    for name in os.listdir(out_dir):
        if name.endswith(".dart") and name not in keep:
            os.remove(os.path.join(out_dir, name))
    test_library = framework(package_dir)
    for name, members in bundles.items():
        with open(os.path.join(package_dir, name), "w", encoding="utf-8") as fh:
            fh.write(client_bundles.bundle_source(members, test_library))
    return bundles, alone


def units(package_dir, files):
    """({bundle: [files]}, the paths flutter test runs) for one package."""
    if client_bundles.per_file_mode():
        return {}, sorted(files)
    bundles, alone = write(package_dir, files)
    return bundles, sorted(bundles) + sorted(alone)


def chrome_test(package_dir, paths, report, log):
    """`flutter test --platform chrome` over [paths]: json results in [report], its output in [log]."""
    args = ["--platform=chrome", "--no-pub", f"--file-reporter=json:{report}"]
    return client_bundles.flutter_test(paths, args, log, app_dir=package_dir)


def run_package(package, files, out_dir, packages=PACKAGES):
    """(exit code, output) for one package's listed files; a bundled failure is rerun alone first."""
    package_dir = os.path.join(packages, package)
    bundles, paths = units(package_dir, files)
    report, log = (os.path.join(out_dir, f"{package}.{ext}") for ext in ("json", "log"))
    retry_report, retry_log = (os.path.join(out_dir, f"{package}-retry.{ext}") for ext in ("json", "log"))
    started = time.monotonic()
    code = chrome_test(package_dir, paths, report, log)
    notes = []
    if code != 0:
        def rerun(failed):
            chrome_test(package_dir, failed, retry_report, retry_log)
            return _read(retry_report)

        code = client_bundles.retry_alone(_read(report), bundles, rerun,
                                          f"client/packages/{package}/", LONE_FILE, notes.append)
    header = (f"::group::flutter test --platform chrome - {package} ({len(files)} files "
              f"in {len(paths)} pages, {time.monotonic() - started:.0f} s)")
    retried = _read(retry_log) if notes else []
    return code, "\n".join([header, *_read(log), *retried, "::endgroup::", *notes])


def run(out_dir, jobs):
    """Runs every listed package [jobs] at a time, the largest first; each prints once it is done."""
    grouped = by_package(entries())
    os.makedirs(out_dir, exist_ok=True)
    status = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        largest_first = sorted(grouped, key=lambda p: (-len(grouped[p]), p))
        running = [pool.submit(run_package, p, grouped[p], out_dir) for p in largest_first]
        for done in concurrent.futures.as_completed(running):
            code, output = done.result()
            print(output, flush=True)
            status = status or code
    return status


def show():
    for package, files in by_package(entries()).items():
        bundles, alone = plan(os.path.join(PACKAGES, package), files)
        print(f"{package}: {len(files)} files, {len(bundles)} bundles, {len(alone)} alone")
        for name, members in bundles.items():
            print(f"  {name}: {len(members)} files")
        for rel, reason in sorted(alone.items()):
            print(f"  {rel}: alone, {reason}")
    return 0


def _read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().splitlines()
    except OSError:
        return []


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("cmd", choices=["run", "plan"])
    parser.add_argument("--out", default=os.path.join(CLIENT, "build", "chrome-tests"))
    parser.add_argument("--jobs", type=int, default=3, help="packages run at once")
    args = parser.parse_args(argv)
    if args.cmd == "plan":
        return show()
    return run(args.out, max(1, args.jobs))


if __name__ == "__main__":
    sys.exit(main())
