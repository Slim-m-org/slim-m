# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How packages/app test files are grouped into shared-isolate bundles."""
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import client_bundle_results  # noqa: E402
import client_bundles  # noqa: E402
import client_shards  # noqa: E402

FILES = client_shards.test_files()
PLAIN = "void main() {\n  test('a', () {});\n}\n"


def _events(path, tests):
    """Flutter json reporter lines: one suite at [path] holding [tests] as (name, result).

    The name LOAD stands for the loader pseudo-test flutter reports per suite.
    """
    full = "/x/client/packages/app/" + path
    lines = [{"suite": {"id": 0, "path": full}}]
    for i, (name, result) in enumerate(tests, start=1):
        loader = name == "LOAD"
        name = f"loading {full}" if loader else name
        lines.append({"type": "testStart", "test": {"id": i, "name": name, "suiteID": 0}})
        lines.append({"type": "testDone", "testID": i, "result": result,
                      "skipped": result == "skipped", "hidden": loader and result == "success"})
    return [json.dumps(e) for e in lines]


class PlanTest(unittest.TestCase):
    def test_every_file_is_bundled_once_or_runs_alone(self):
        bundles, alone = client_bundles.plan()
        bundled = [f for files in bundles.values() for f in files]
        self.assertEqual(len(bundled), len(set(bundled)))
        self.assertEqual(sorted(bundled + list(alone)), FILES)

    def test_every_listed_lone_file_exists(self):
        stale = sorted(set(client_bundles.load_lone()) - set(FILES))
        self.assertEqual(stale, [], "remove these from client_bundle_lone.txt")

    def test_dealt_units_cover_every_file_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp)
            for rel in ("test/a/one_test.dart", "test/a/two_test.dart", "test/b_test.dart",
                        "test/snapshots/s_test.dart"):
                (app / rel).parent.mkdir(parents=True, exist_ok=True)
                (app / rel).write_text(PLAIN)
            bundles, alone = client_bundles.plan(str(app), {}, {})
            seen = []
            for index in range(3):
                for unit in client_bundles.units(str(app), {}, shards=3, index=index):
                    seen += bundles.get(unit, [unit])
            self.assertEqual(sorted(seen), sorted(client_shards.test_files(str(app))))
            self.assertIn("test/snapshots/s_test.dart", alone)

    def test_bundles_go_to_a_gitignored_folder(self):
        probe = os.path.join(client_bundles.APP_DIR, client_bundles.BUNDLE_DIR, "x_0.dart")
        ignored = subprocess.run(["git", "check-ignore", "-q", probe],
                                 cwd=client_bundles.APP_DIR, check=False)
        self.assertEqual(ignored.returncode, 0)

    def test_write_removes_a_stale_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp)
            (app / "test/a").mkdir(parents=True)
            (app / "test/a/one_test.dart").write_text(PLAIN)
            stale = app / client_bundles.BUNDLE_DIR / "gone_0.dart"
            stale.parent.mkdir(parents=True)
            stale.write_text("")
            client_bundles.write(str(app), {}, {})
            self.assertFalse(stale.exists())
            self.assertTrue((app / client_bundles.BUNDLE_DIR / "a_0.dart").exists())


class LoneReasonTest(unittest.TestCase):
    def reason(self, source, path="test/a_test.dart", lone=None):
        return client_bundles.lone_reason(path, source, lone)

    def test_a_plain_file_is_bundled(self):
        self.assertIsNone(self.reason(PLAIN))

    def test_an_async_main_runs_alone(self):
        self.assertIsNotNone(self.reason("Future<void> main() async {}\n"))
        self.assertIsNotNone(self.reason("void main() async {}\n"))

    def test_each_isolate_wide_pattern_runs_alone(self):
        for code in ("tearDownAll(() {});", "HttpOverrides.global = x;",
                     "IOOverrides.global = x;", "Directory.current = d;",
                     "Platform.script;", "await HttpServer.bind('127.0.0.1', 0);",
                     "WebSocket.connect(url);", "LiveTestWidgetsFlutterBinding.ensureInitialized();",
                     "expect(f, matchesGoldenFile('a.png'));"):
            source = "void main() {\n  " + code + "\n}\n"
            self.assertIsNotNone(self.reason(source), code)

    def test_a_library_level_test_annotation_runs_alone(self):
        for annotation in ("@TestOn('browser')", "@Timeout(Duration(minutes: 2))", "@Tags(['slow'])"):
            self.assertIsNotNone(self.reason(annotation + "\nlibrary;\n\n" + PLAIN), annotation)

    def test_a_pattern_in_a_comment_or_string_is_not_code(self):
        source = "// tearDownAll(\nvoid main() {\n  test('HttpOverrides.global = x', () {});\n}\n"
        self.assertIsNone(self.reason(source))

    def test_the_snapshot_matrix_runs_alone(self):
        self.assertIsNotNone(self.reason(PLAIN, "test/snapshots/x_test.dart"))
        self.assertIsNotNone(self.reason(PLAIN, "test/ui_snapshot_x_test.dart"))

    def test_the_committed_list_wins(self):
        self.assertEqual(self.reason(PLAIN, lone={"test/a_test.dart": "leaks"}), "leaks")


class ShapeTest(unittest.TestCase):
    def test_folder_keys(self):
        key = client_bundles.folder_key
        self.assertEqual(key("test/features/voice/x/y_test.dart"), "test/features/voice")
        self.assertEqual(key("test/sync/x_test.dart"), "test/sync")
        self.assertEqual(key("test/x_test.dart"), "test")

    def test_files_that_load_real_fonts_share_bundles_only_with_each_other(self):
        key = client_bundles.bundle_key
        fonts = "void main() {\n  setUpAll(loadRealFonts);\n}\n"
        self.assertEqual(key("test/features/voice/a_test.dart", fonts), "features_voice_fonts")
        self.assertEqual(key("test/features/voice/b_test.dart", PLAIN), "features_voice")
        self.assertEqual(key("test/b_test.dart", "// loadRealFonts\n" + PLAIN), "root")
        both = "void main() {\n  setUpAll(mockAppVersion);\n  setUpAll(loadRealFonts);\n}\n"
        self.assertEqual(key("test/sync/c_test.dart", both), "sync_fonts_appinfo")

    def test_chunks_keep_order_and_balance(self):
        files = [f"test/f{i:02}_test.dart" for i in range(40)]
        durations = {f: 3.7 for f in files}
        chunks = client_bundles.chunk(files, durations, limit=30)
        self.assertEqual([f for c in chunks for f in c], files)
        self.assertEqual(len(chunks), 4)
        self.assertLessEqual(max(map(len, chunks)) - min(map(len, chunks)), 1)

    def test_a_bundle_groups_each_file_under_its_path(self):
        source = client_bundles.bundle_source(["test/a/x_test.dart"])
        self.assertIn("import '../a/x_test.dart' as t0;", source)
        self.assertIn("group('test/a/x_test.dart', t0.main);", source)

    def test_a_path_that_would_break_the_dart_string_is_refused(self):
        with self.assertRaises(ValueError):
            client_bundles.bundle_source(["test/it's_test.dart"])


class CompareTest(unittest.TestCase):
    BUNDLES = {"test/.bundles/a_0.dart": ["test/a/x_test.dart", "test/a/y_test.dart"]}

    def compare(self, per_file_lines, bundled_lines):
        per_file = client_bundle_results.results(per_file_lines, self.BUNDLES)
        bundled = client_bundle_results.results(bundled_lines, self.BUNDLES)
        return client_bundle_results.differences(per_file, bundled, ["test/a/x_test.dart"])

    def test_the_same_results_match(self):
        per_file = _events("test/a/x_test.dart", [("LOAD", "success"), ("t1", "success")])
        bundled = _events("test/.bundles/a_0.dart",
                          [("LOAD", "success"), ("test/a/x_test.dart t1", "success")])
        self.assertEqual(self.compare(per_file, bundled), [])

    def test_a_test_that_fails_only_when_bundled_differs(self):
        per_file = _events("test/a/x_test.dart", [("t1", "success")])
        bundled = _events("test/.bundles/a_0.dart", [("test/a/x_test.dart t1", "failure")])
        [(path, only_alone, only_bundled)] = self.compare(per_file, bundled)
        self.assertEqual(path, "test/a/x_test.dart")
        self.assertEqual(list(only_alone), [("t1", "success")])
        self.assertEqual(list(only_bundled), [("t1", "failure")])

    def test_a_bundle_that_fails_to_load_fails_every_member(self):
        per_file = _events("test/a/x_test.dart", [("t1", "success")])
        bundled = _events("test/.bundles/a_0.dart", [("LOAD", "error")])
        self.assertEqual(len(self.compare(per_file, bundled)), 1)

    def test_a_test_named_loading_is_still_a_test(self):
        per_file = _events("test/a/x_test.dart", [("loading shows a spinner", "success")])
        bundled = _events("test/.bundles/a_0.dart",
                          [("test/a/x_test.dart loading shows a spinner", "success")])
        self.assertEqual(self.compare(per_file, bundled), [])

    def test_an_error_after_a_test_finished_differs(self):
        per_file = _events("test/a/x_test.dart", [("t1", "success")])
        bundled = _events("test/.bundles/a_0.dart", [("test/a/x_test.dart t1", "success")])
        bundled.append(json.dumps({"type": "error", "testID": 1, "error": "late"}))
        [(_, _, only_bundled)] = self.compare(per_file, bundled)
        self.assertEqual(list(only_bundled), [("t1", "error after it finished")])

    def test_a_dropped_test_differs(self):
        per_file = _events("test/a/x_test.dart", [("t1", "success"), ("t2", "success")])
        bundled = _events("test/.bundles/a_0.dart", [("test/a/x_test.dart t1", "success")])
        self.assertEqual(len(self.compare(per_file, bundled)), 1)


class RetryTest(unittest.TestCase):
    BUNDLES = {"test/.bundles/a_0.dart": ["test/a/x_test.dart"]}

    def retry(self, report, rerun):
        """retry()'s exit code and printed lines, with flutter faked to report [rerun]."""
        with tempfile.TemporaryDirectory(dir=os.getcwd()) as tmp:
            report_path = os.path.join(tmp, "report.json")
            Path(report_path).write_text("\n".join(report))

            def fake_flutter(paths, args, out_path=None):
                Path(args[-1].removeprefix("--file-reporter=json:")).write_text("\n".join(rerun))
                return 0

            with mock.patch.object(client_bundles, "plan", return_value=(self.BUNDLES, {})), \
                    mock.patch.object(client_bundles, "flutter_test", fake_flutter), \
                    mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                code = client_bundles.retry(report_path, 2, tmp)
            return code, out.getvalue()

    def test_a_file_that_passes_alone_is_a_leak_warning(self):
        report = _events("test/.bundles/a_0.dart", [("test/a/x_test.dart t1", "failure")])
        code, out = self.retry(report, _events("test/a/x_test.dart", [("t1", "success")]))
        self.assertEqual(code, 0)
        self.assertIn("::warning file=client/packages/app/test/a/x_test.dart", out)

    def test_a_file_that_fails_alone_too_fails(self):
        report = _events("test/.bundles/a_0.dart", [("test/a/x_test.dart t1", "failure")])
        code, out = self.retry(report, _events("test/a/x_test.dart", [("t1", "failure")]))
        self.assertEqual(code, 1)
        self.assertIn("::error", out)

    def test_a_bundled_file_run_alone_is_never_retried(self):
        report = _events("test/a/x_test.dart", [("t1", "failure")])
        code, _ = self.retry(report, _events("test/a/x_test.dart", [("t1", "success")]))
        self.assertEqual(code, 1)

    def test_a_failure_outside_a_bundle_is_never_retried(self):
        report = _events("test/b_test.dart", [("t1", "failure")])
        code, _ = self.retry(report, [])
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
