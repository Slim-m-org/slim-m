# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How client/chrome-tests.txt is bundled into one page per package and run."""
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import chrome_bundles  # noqa: E402
from config_source import strip_comments  # noqa: E402
from test_windows_builds_do_not_run_under_bash import jobs, steps  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PLAIN = "void main() {\n  test('a', () {});\n}\n"
FLUTTER_PUBSPEC = "name: p\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n"
DART_PUBSPEC = "name: p\ndev_dependencies:\n  test: ^1.25.0\n"


def _events(path, tests):
    """Flutter json reporter lines: one suite at [path] holding [tests] as (name, result)."""
    full = "/x/client/packages/p/" + path
    lines = [{"suite": {"id": 0, "path": full}}]
    for i, (name, result) in enumerate(tests, start=1):
        lines.append({"type": "testStart", "test": {"id": i, "name": name, "suiteID": 0}})
        lines.append({"type": "testDone", "testID": i, "result": result,
                      "skipped": False, "hidden": False})
    return "\n".join(json.dumps(e) for e in lines)


def _package(root, pubspec, files):
    """A package called p under [root] with [files] {test path: source}."""
    pkg = Path(root) / "p"
    for rel, source in files.items():
        (pkg / rel).parent.mkdir(parents=True, exist_ok=True)
        (pkg / rel).write_text(source)
    (pkg / "pubspec.yaml").write_text(pubspec)
    return pkg


class ScriptTest(unittest.TestCase):
    def test_the_script_refuses_an_unknown_option_before_running_anything(self):
        result = subprocess.run(["bash", str(ROOT / "scripts" / "chrome-tests.sh"), "--shards", "2"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2, result.stderr)


class PlanTest(unittest.TestCase):
    def test_every_listed_file_is_bundled_once_or_runs_alone(self):
        for package, files in chrome_bundles.by_package(chrome_bundles.entries()).items():
            with self.subTest(package=package):
                bundles, alone = chrome_bundles.plan(
                    os.path.join(chrome_bundles.PACKAGES, package), files)
                bundled = [f for members in bundles.values() for f in members]
                self.assertEqual(sorted(bundled + list(alone)), sorted(files))

    def test_every_listed_lone_file_is_on_the_chrome_list(self):
        stale = set(chrome_bundles.client_bundles.load_lone(chrome_bundles.LONE_FILE))
        self.assertEqual(sorted(stale - set(chrome_bundles.entries())), [])

    def test_bundles_go_to_a_gitignored_folder_in_every_package(self):
        for package in chrome_bundles.by_package(chrome_bundles.entries()):
            probe = os.path.join(chrome_bundles.PACKAGES, package, chrome_bundles.BUNDLE_DIR, "all.dart")
            ignored = subprocess.run(["git", "check-ignore", "-q", probe], cwd=ROOT, check=False)
            self.assertEqual(ignored.returncode, 0, package)

    def test_a_package_without_flutter_test_bundles_with_package_test(self):
        app = os.path.join(chrome_bundles.PACKAGES, "app")
        api = os.path.join(chrome_bundles.PACKAGES, "api")
        self.assertEqual(chrome_bundles.framework(app), "package:flutter_test/flutter_test.dart")
        self.assertEqual(chrome_bundles.framework(api), "package:test/test.dart")

    def test_sticky_state_and_annotations_keep_files_apart(self):
        with tempfile.TemporaryDirectory() as tmp:
            pkg = _package(tmp, FLUTTER_PUBSPEC, {
                "test/a_test.dart": PLAIN,
                "test/b_test.dart": "void main() {\n  setUpAll(loadRealFonts);\n}\n",
                "test/c_test.dart": "@TestOn('browser')\nlibrary;\n\n" + PLAIN,
                "test/d_test.dart": "Future<void> main() async {}\n",
            })
            files = ["test/a_test.dart", "test/b_test.dart", "test/c_test.dart", "test/d_test.dart"]
            bundles, alone = chrome_bundles.plan(str(pkg), files, lone={"p/test/a_test.dart": "leaks"})
        self.assertEqual(bundles, {"test/.chrome_bundles/all_fonts.dart": ["test/b_test.dart"]})
        self.assertEqual(sorted(alone), ["test/a_test.dart", "test/c_test.dart", "test/d_test.dart"])
        self.assertEqual(alone["test/a_test.dart"], "leaks")


class RunTest(unittest.TestCase):
    def run_package(self, pubspec, outcomes, per_file=False):
        """run_package's exit code, output, the paths flutter was handed, and the bundle source."""
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            pkg = _package(tmp, pubspec, {"test/a_test.dart": PLAIN, "test/b/c_test.dart": PLAIN})
            stale = pkg / chrome_bundles.BUNDLE_DIR / "gone.dart"
            stale.parent.mkdir(parents=True)
            stale.write_text("")

            def fake_flutter(paths, args, out_path, app_dir):
                calls.append(list(paths))
                outcome = outcomes[len(calls) - 1]
                report = next(a for a in args if a.startswith("--file-reporter=json:"))
                Path(report.removeprefix("--file-reporter=json:")).write_text(outcome)
                Path(out_path).write_text(f"flutter output {len(calls)}")
                return 1 if "failure" in outcome else 0

            env = {"SLIMM_TEST_PER_FILE": "1"} if per_file else {}
            with mock.patch.object(chrome_bundles.client_bundles, "flutter_test", fake_flutter), \
                    mock.patch.dict(os.environ, env):
                code, out = chrome_bundles.run_package(
                    "p", ["test/a_test.dart", "test/b/c_test.dart"], tmp, packages=tmp)
            bundle = pkg / chrome_bundles.BUNDLE_DIR / "all.dart"
            source = bundle.read_text() if bundle.exists() else None
            self.assertNotEqual(stale.exists(), not per_file)
            return code, out, calls, source

    def test_a_package_runs_as_one_page(self):
        passed = _events("test/.chrome_bundles/all.dart", [("test/a_test.dart a", "success")])
        code, out, calls, source = self.run_package(DART_PUBSPEC, [passed])
        self.assertEqual(code, 0)
        self.assertEqual(calls, [["test/.chrome_bundles/all.dart"]])
        self.assertIn("flutter output 1", out)
        self.assertIn("import 'package:test/test.dart';", source)
        self.assertIn("group('test/b/c_test.dart', t1.main);", source)

    def test_a_bundled_failure_that_passes_alone_is_a_leak_warning(self):
        failed = _events("test/.chrome_bundles/all.dart", [("test/b/c_test.dart a", "failure")])
        alone = _events("test/b/c_test.dart", [("a", "success")])
        code, out, calls, _ = self.run_package(FLUTTER_PUBSPEC, [failed, alone])
        self.assertEqual(code, 0)
        self.assertEqual(calls[1], ["test/b/c_test.dart"])
        self.assertIn("::warning file=client/packages/p/test/b/c_test.dart", out)
        self.assertIn("chrome_bundle_lone.txt", out)
        self.assertIn("flutter output 2", out)

    def test_a_bundled_failure_that_fails_alone_too_fails(self):
        failed = _events("test/.chrome_bundles/all.dart", [("test/a_test.dart a", "failure")])
        alone = _events("test/a_test.dart", [("a", "failure")])
        code, out, _, _ = self.run_package(FLUTTER_PUBSPEC, [failed, alone])
        self.assertEqual(code, 1)
        self.assertIn("::error file=client/packages/p/test/a_test.dart", out)

    def test_per_file_mode_hands_flutter_the_files_themselves(self):
        passed = _events("test/a_test.dart", [("a", "success")])
        code, _, calls, _ = self.run_package(FLUTTER_PUBSPEC, [passed], per_file=True)
        self.assertEqual(code, 0)
        self.assertEqual(calls, [["test/a_test.dart", "test/b/c_test.dart"]])


class PoolTest(unittest.TestCase):
    def test_every_package_runs_and_one_failure_fails_the_job(self):
        listed = ["a/test/x_test.dart", "b/test/x_test.dart", "b/test/y_test.dart"]
        seen = []

        def fake_package(package, files, out_dir):
            seen.append((package, files))
            return (1 if package == "a" else 0), f"output of {package}"

        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(chrome_bundles, "entries", return_value=listed), \
                mock.patch.object(chrome_bundles, "run_package", fake_package), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            code = chrome_bundles.run(tmp, jobs=1)
        self.assertEqual(code, 1)
        self.assertEqual(seen, [("b", ["test/x_test.dart", "test/y_test.dart"]), ("a", ["test/x_test.dart"])])
        self.assertIn("output of a", out.getvalue())
        self.assertIn("output of b", out.getvalue())


class WorkflowTest(unittest.TestCase):
    def test_the_job_uploads_the_logs_when_it_fails_or_is_cancelled(self):
        """A package prints only once it finishes, so a job killed at its limit has its logs only on disk."""
        workflow = strip_comments((ROOT / ".github" / "workflows" / "client-ci.yml").read_text())
        out = os.path.relpath(chrome_bundles.OUT_DIR, ROOT)
        uploads = [s for s in steps(jobs(workflow)["test-chrome"]) if "actions/upload-artifact@" in s]
        kept = [s for s in uploads
                if re.search(rf"^\s+path:\s*{re.escape(out)}/?\s*$", s, re.M)
                and re.search(r"^\s+if:.*(always\(\)|failure\(\).*cancelled\(\))", s, re.M)]
        self.assertEqual(len(kept), 1, f"test-chrome uploads {out} on failure or cancel once")

    def test_the_script_writes_where_the_job_uploads_from(self):
        with mock.patch.object(chrome_bundles, "run", return_value=0) as run:
            chrome_bundles.main(["run"])
        run.assert_called_once_with(chrome_bundles.OUT_DIR, 3)


if __name__ == "__main__":
    unittest.main()
