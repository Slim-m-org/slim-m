# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/check-ref-after-await.py.

The end-to-end run reads the real tree, where the allowlist keeps it green, so
the shapes the gate exists for are checked here against fixture sources.
"""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-ref-after-await.py"
APP = "client/packages/app/lib/src/features/x/widgets/"


def _load():
    spec = importlib.util.spec_from_file_location("ref_after_await", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _widget(body: str) -> str:
    return (
        "class S extends ConsumerState<W> {\n"
        f"{body}\n"
        "}\n"
    )


class UsesAfterAwaitTest(unittest.TestCase):
    def setUp(self):
        self.mod = _load()

    def hits(self, body: str) -> list[int]:
        return self.mod.uses_after_await(_widget(body))

    def test_ref_after_an_await_is_flagged(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  await api.send();\n"
                "  ref.invalidate(p);\n"
                "}"
            ),
            [4],
        )

    def test_set_state_after_an_await_is_flagged(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  await api.send();\n"
                "  setState(() {});\n"
                "}"
            ),
            [4],
        )

    def test_a_mounted_check_clears_it(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  await api.send();\n"
                "  if (!mounted) return;\n"
                "  ref.invalidate(p);\n"
                "}"
            ),
            [],
        )

    def test_a_context_mounted_check_clears_it(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  await api.send();\n"
                "  if (!context.mounted) return;\n"
                "  ref.read(p);\n"
                "}"
            ),
            [],
        )

    def test_ref_in_the_awaited_expression_is_clean(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  final v = await ref.read(p.future);\n"
                "}"
            ),
            [],
        )

    def test_ref_before_the_first_await_is_clean(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  final actions = ref.read(p);\n"
                "  await actions.send();\n"
                "}"
            ),
            [],
        )

    def test_a_container_after_an_await_is_clean(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  final container = ProviderScope.containerOf(context, listen: false);\n"
                "  await api.send();\n"
                "  container.invalidate(p);\n"
                "}"
            ),
            [],
        )

    def test_a_branch_that_returns_does_not_taint_the_rest(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  if (a) {\n"
                "    await api.send();\n"
                "    return;\n"
                "  }\n"
                "  ref.read(p);\n"
                "}"
            ),
            [],
        )

    def test_a_branch_that_falls_through_does_taint_the_rest(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  if (a) {\n"
                "    await api.send();\n"
                "  }\n"
                "  ref.read(p);\n"
                "}"
            ),
            [6],
        )

    def test_another_function_is_not_tainted_by_an_await(self):
        self.assertEqual(
            self.hits(
                "Future<void> a() async {\n"
                "  await api.send();\n"
                "}\n"
                "void b() {\n"
                "  ref.read(p);\n"
                "}"
            ),
            [],
        )

    def test_a_closure_is_its_own_function(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  await api.send();\n"
                "  later(() {\n"
                "    ref.read(p);\n"
                "  });\n"
                "}"
            ),
            [],
        )

    def test_a_comment_or_string_naming_the_shape_is_ignored(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  await api.send();\n"
                "  // ref.read(p) is wrong here\n"
                "  final s = 'ref.invalidate(p)';\n"
                "}"
            ),
            [],
        )

    def test_ref_context_is_not_a_provider_use(self):
        self.assertEqual(
            self.hits(
                "Future<void> go() async {\n"
                "  await api.send();\n"
                "  if (!ref.context.mounted) return;\n"
                "}"
            ),
            [],
        )


class OffendersTest(unittest.TestCase):
    def setUp(self):
        self.mod = _load()
        self.seeded = _widget(
            "Future<void> go() async {\n"
            "  await api.send();\n"
            "  ref.invalidate(p);\n"
            "}"
        )

    def test_a_seeded_use_is_reported_with_its_path_and_line(self):
        found = self.mod.offenders_in({APP + "a.dart": self.seeded}, {})
        self.assertEqual(found, [APP + "a.dart:4"])

    def test_the_allowlist_is_a_ceiling_per_file(self):
        path = APP + "a.dart"
        self.assertEqual(self.mod.offenders_in({path: self.seeded}, {path: 1}), [])
        twice = self.seeded + self.seeded
        self.assertEqual(self.mod.offenders_in({path: twice}, {path: 1}), [path + ":10"])

    def test_provider_files_are_out_of_scope(self):
        path = "client/packages/app/lib/src/features/x/providers/a.dart"
        self.assertEqual(self.mod.offenders_in({path: self.seeded}, {}), [])

    def test_files_outside_the_app_package_are_out_of_scope(self):
        path = "client/packages/rtc/lib/src/a.dart"
        self.assertEqual(self.mod.offenders_in({path: self.seeded}, {}), [])

    def test_an_entry_above_what_the_file_holds_is_stale(self):
        path = APP + "a.dart"
        self.assertEqual(self.mod.stale_entries({path: self.seeded}, {path: 1}), [])
        self.assertEqual(
            self.mod.stale_entries({path: self.seeded}, {path: 3}),
            [f"{path} lists 3 but holds 1"],
        )
        self.assertEqual(
            self.mod.stale_entries({}, {path: 1}), [f"{path} lists 1 but holds 0"]
        )

    def test_the_real_tree_passes_against_its_allowlist(self):
        done = subprocess.run(
            [sys.executable, str(SCRIPT)], capture_output=True, text=True, cwd=SCRIPT.parent
        )
        self.assertEqual(done.returncode, 0, done.stdout)


class LoadAllowlistTest(unittest.TestCase):
    def test_a_bare_path_allows_one_and_a_count_sets_the_ceiling(self):
        mod = _load()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "allow.txt"
            path.write_text("# header\n\na/b.dart # why\nc/d.dart 3 # three\n")
            self.assertEqual(mod.load_allowlist(path), {"a/b.dart": 1, "c/d.dart": 3})


if __name__ == "__main__":
    unittest.main()
