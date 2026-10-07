# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Turns what ui-capture.sh actually did into a manifest and a contact sheet.

Nothing here keeps its own list of what should exist. A category's image
gallery is whatever PNGs are sitting in its build/ui-capture/images/<category>
directory, and a category's pass/fail summary is read straight out of each
job's own `flutter test --file-reporter=json:...` log (see
https://dart.dev/go/test-docs/json_reporter.md for the event shapes). That is
the same discipline `e2e_coverage.py`'s own doc comment argues for: a
hand-kept expected-list drifts the moment a harness changes, and reading the
real signal cannot.

A job's meta file (written by ui-capture.sh) also carries how many images it
wrote this run. A job whose log shows at least one passing, visible test but
recorded zero images is the "silently missing file" case CLAUDE.md keeps
finding elsewhere in this project: a test that reports success while writing
nothing. That is flagged as a failure here, not just a warning, because a
green test and an absent picture is exactly the gap this tool exists to catch.

HTML rendering lives in `ui_capture_html.py`; this file only builds the
manifest that page reads.
"""
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

from ui_capture_html import collect_failures, render_html

HIDDEN_TEST_NAMES = {"(setUpAll)", "(tearDownAll)"}
UNREADABLE_LOG = "(unreadable log)"


def parse_job_log(path):
    """Visible tests (name, result, error) out of one JSON-lines report."""
    if not path.exists():
        return None
    starts, errors = {}, {}
    tests = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError as exc:
            tests.append(
                {
                    "name": UNREADABLE_LOG,
                    "result": "error",
                    "error": f"the log stops at a line that is not JSON ({exc}); "
                    "the run was probably killed",
                }
            )
            break
        kind = event.get("type")
        if kind == "testStart":
            starts[event["test"]["id"]] = event["test"]
        elif kind == "error":
            test_id = event["testID"]
            errors[test_id] = errors.get(test_id, "") + event.get("error", "")
        elif kind == "testDone":
            test_id = event["testID"]
            test = starts.get(test_id, {})
            if event.get("hidden") or test.get("name") in HIDDEN_TEST_NAMES:
                continue
            tests.append(
                {
                    "name": test.get("name", f"test {test_id}"),
                    "result": event.get("result"),
                    "error": errors.get(test_id),
                }
            )
    return tests


def load_jobs(work):
    """Every job ui-capture.sh has ever recorded a .meta file for, across
    however many partial reruns produced the current build/ui-capture."""
    jobs = []
    for meta_path in sorted(work.glob("*.meta")):
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            meta["tests"] = parse_job_log(work / f"{meta['id']}.json")
        except (OSError, ValueError, KeyError, TypeError):
            meta = {
                "id": meta_path.stem,
                "category": "unreadable",
                "test_file": None,
                "exit_code": 1,
                "images": 0,
                "tests": [
                    {
                        "name": f"{meta_path.name} is unreadable",
                        "result": "error",
                        "error": "the job's meta file is not valid JSON",
                    }
                ],
            }
        jobs.append(meta)
    return jobs


def job_summary(job):
    tests = job["tests"] or []
    passed = [t for t in tests if t["result"] == "success"]
    failed = [t for t in tests if t["result"] != "success"]
    silent_gap = bool(passed) and job["images"] == 0
    return {
        "total": len(tests),
        "passed": len(passed),
        "failed": failed,
        "silent_gap": silent_gap,
    }


def build_manifest(out_dir, work_dir):
    jobs = load_jobs(work_dir)
    categories = {}
    for job in jobs:
        summary = job_summary(job)
        entry = categories.setdefault(
            job["category"],
            {"id": job["category"], "jobs": [], "images": []},
        )
        entry["jobs"].append({**job, "summary": summary})
    for category, entry in categories.items():
        image_dir = out_dir / "images" / category
        if image_dir.is_dir():
            entry["images"] = sorted(p.name for p in image_dir.glob("*.png"))
    manifest = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "categories": categories,
    }
    manifest["ok"] = not collect_failures(manifest)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    args = parser.parse_args()

    manifest = build_manifest(args.out, args.work)
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    (args.out / "index.html").write_text(render_html(manifest))

    total_images = sum(len(entry["images"]) for entry in manifest["categories"].values())
    total_failures = len(collect_failures(manifest))
    print(
        f"report: {total_images} image(s) across {len(manifest['categories'])} "
        f"categor(y/ies), {total_failures} failure(s)"
    )
    return 0 if manifest["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
