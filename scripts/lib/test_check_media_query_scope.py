# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for the allowlist parsing in scripts/check-media-query-scope.py.

The regression this exists for: the allowlist used to exempt a whole file, so a
second, unrelated `MediaQuery.of(` added to an already-listed file was never
flagged - and the listed files are exactly the ones most likely to accumulate
more `MediaQuery` use. It is a per-file ceiling now, the same ratchet
`check-comment-cap.sh` uses.

Deliberately a count and not a line number: a line number drifts with every
edit above it, so it would have to be re-recorded on unrelated changes, while a
count only moves when the thing being counted does. The end-to-end behaviour
(only the calls past the ceiling are reported) is checked against the real
repository, since `ALLOWLIST_PATH` resolves beside the script rather than inside
whatever tree is being scanned.
"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-media-query-scope.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("mq_scope", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LoadAllowlistTest(unittest.TestCase):
    def setUp(self):
        self.mod = _load_module()
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def _allowlist(self, body: str) -> dict:
        path = Path(self._tmp.name) / "allow.txt"
        path.write_text(body)
        return self.mod.load_allowlist(path)

    def test_a_bare_path_allows_exactly_one_call(self):
        self.assertEqual(
            self._allowlist("a/b.dart # needs the whole object\n"),
            {"a/b.dart": 1},
        )

    def test_an_explicit_count_sets_the_ceiling(self):
        self.assertEqual(
            self._allowlist("a/b.dart 3 # three copyWith overrides\n"),
            {"a/b.dart": 3},
        )

    def test_comments_and_blank_lines_are_skipped(self):
        self.assertEqual(
            self._allowlist("# a header\n\n   \na/b.dart # why\n"),
            {"a/b.dart": 1},
        )

    def test_the_real_allowlist_parses_and_lists_only_existing_files(self):
        allowed = self.mod.load_allowlist(self.mod.ALLOWLIST_PATH)
        self.assertTrue(allowed, "the real allowlist should not read as empty")
        root = SCRIPT.resolve().parents[1]
        for rel, ceiling in allowed.items():
            with self.subTest(path=rel):
                self.assertTrue(
                    (root / rel).exists(),
                    "a listed path that no longer exists silently stops "
                    "protecting anything",
                )
                self.assertGreaterEqual(ceiling, 1)


class OffenderCeilingTest(unittest.TestCase):
    def setUp(self):
        self.mod = _load_module()

    """The per-file ceiling itself, which the real-repository run cannot reach.

    The gate's own history is the reason this exists: the allowlist used to
    exempt a whole file, so a second, unrelated `MediaQuery.of(` added to a
    listed file went unflagged. The fix is a per-file ceiling - and no
    allowlisted file in the tree today holds more than its count, so an
    end-to-end run over the real repository would pass either way.
    """

    def test_a_listed_file_stays_quiet_up_to_its_count(self):
        source = "MediaQuery.of(context);\nMediaQuery.of(context);\n"
        self.assertEqual(
            self.mod.offenders_in({"a.dart": source}, {"a.dart": 2}),
            [],
        )

    def test_the_call_past_the_ceiling_is_reported(self):
        source = "MediaQuery.of(context);\nMediaQuery.of(context);\n"
        self.assertEqual(
            self.mod.offenders_in({"a.dart": source}, {"a.dart": 1}),
            ["a.dart:2"],
            "a blanket per-file exemption is the bug this gate was fixed for",
        )

    def test_an_unlisted_file_is_reported_from_its_first_call(self):
        self.assertEqual(
            self.mod.offenders_in({"a.dart": "MediaQuery.of(context);\n"}, {}),
            ["a.dart:1"],
        )

    def test_a_call_inside_a_block_comment_does_not_count(self):
        source = "/* MediaQuery.of(context); */\nMediaQuery.of(context);\n"
        self.assertEqual(
            self.mod.offenders_in({"a.dart": source}, {}),
            ["a.dart:2"],
            "a commented-out call is not a subscription",
        )

    def test_maybe_of_is_reported_like_of(self):
        source = "final w = MediaQuery.maybeOf(context)?.size.width;\n"
        self.assertEqual(
            self.mod.offenders_in({"a.dart": source}, {}),
            ["a.dart:1"],
            "maybeOf subscribes to the whole MediaQueryData exactly like of",
        )

    def test_scoped_maybe_accessors_stay_allowed(self):
        source = "MediaQuery.maybeSizeOf(context);\nMediaQuery.maybeViewInsetsOf(context);\n"
        self.assertEqual(self.mod.offenders_in({"a.dart": source}, {}), [])


if __name__ == "__main__":
    unittest.main()
