# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""check-comment-cap.sh must count runs in every language it scans: shell, YAML, TOML, native and web sources.

Each case builds a throwaway git repo holding a copy of the script, because the
script reads `git ls-files` from its own toplevel and takes no file arguments.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-comment-cap.sh"


def _run_gate(files: dict[str, str], allow: str = "") -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory(prefix="comment-cap-") as tmp:
        root = Path(tmp)
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        (root / "scripts").mkdir()
        shutil.copy(SCRIPT, root / "scripts" / SCRIPT.name)
        (root / "scripts" / "comment-cap-allow.txt").write_text(allow)
        for rel, body in files.items():
            target = root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(body)
        # The copied script stays untracked so the gate does not scan itself.
        subprocess.run(["git", "add", *files], cwd=root, check=True)
        return subprocess.run(
            ["bash", "scripts/check-comment-cap.sh"],
            cwd=root, capture_output=True, text=True,
        )


HEADER = "#!/usr/bin/env bash\n# SPDX-License-Identifier: MIT\n#\n# What this does.\n# And why.\n\n"
TWO_LINE_RUN = "# first line of a why\n# second line of a why\n"


class CommentCapHashFilesTest(unittest.TestCase):
    def test_two_line_run_in_shell_fails(self):
        result = _run_gate({"a.sh": HEADER + "set -e\n" + TWO_LINE_RUN + "true\n"})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("a.sh", result.stderr)

    def test_two_line_run_in_workflow_run_block_fails(self):
        yml = "name: x\njobs:\n  a:\n    steps:\n      - run: |\n          " + \
            TWO_LINE_RUN.replace("\n# ", "\n          # ") + "          true\n"
        result = _run_gate({".github/workflows/x.yml": yml})
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_two_line_run_in_toml_fails(self):
        result = _run_gate({"c.toml": "[a]\n" + TWO_LINE_RUN + "b = 1\n"})
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_shebang_and_multi_line_header_are_not_a_run(self):
        result = _run_gate({"a.sh": HEADER + "set -e\n# one line\ntrue\n"})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_yaml_header_block_is_not_a_run(self):
        yml = "# SPDX-License-Identifier: MIT\n# what this file is\n\nname: x\n"
        result = _run_gate({"a.yml": yml})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_allowlist_holds_a_listed_run_and_not_a_second(self):
        body = HEADER + "true\n" + TWO_LINE_RUN + "true\n"
        self.assertEqual(_run_gate({"a.sh": body}, "a.sh 1\n").returncode, 0)
        second = body + TWO_LINE_RUN
        self.assertEqual(_run_gate({"a.sh": second}, "a.sh 1\n").returncode, 1)

    def test_entry_above_the_real_count_fails(self):
        body = HEADER + "true\n" + TWO_LINE_RUN + "true\n"
        result = _run_gate({"a.sh": body}, "a.sh 2\n")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("lower the entry", result.stderr)

    def test_entry_of_a_clean_file_fails(self):
        result = _run_gate({"a.sh": HEADER + "true\n"}, "a.sh 1\n")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("drop the line", result.stderr)

    def test_slashes_in_shell_are_not_comments(self):
        body = HEADER + "cat <<EOF\n// not a comment\n// still not\nEOF\n"
        self.assertEqual(_run_gate({"a.sh": body}).returncode, 0)


SLASH_RUN = "// first line of a why\n// second line of a why\n"


class CommentCapNativeAndRustFilesTest(unittest.TestCase):
    def test_a_two_line_slash_run_fails_in_every_native_and_web_language(self):
        for suffix in ("swift", "kt", "kts", "c", "cc", "cpp", "h", "m", "ts", "tsx", "js", "mjs"):
            with self.subTest(suffix=suffix):
                result = _run_gate({f"a.{suffix}": "let a = 1\n" + SLASH_RUN + "let b = 2\n"})
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"a.{suffix}", result.stderr)

    def test_a_multi_line_block_comment_fails_in_c(self):
        result = _run_gate({"a.cc": "int a;\n/* one\n   two */\nint b;\n"})
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_stacked_rust_attributes_are_not_a_comment_run(self):
        body = "#[derive(Debug)]\n#[serde(rename_all = \"snake_case\")]\nstruct A;\n"
        self.assertEqual(_run_gate({"a.rs": body}).returncode, 0)

    def test_stacked_c_directives_are_not_a_comment_run(self):
        body = "#include <a.h>\n#include <b.h>\n#define X 1\n"
        self.assertEqual(_run_gate({"a.cc": body, "b.h": body}).returncode, 0)

    def test_a_python_hash_run_still_counts_and_slashes_do_not(self):
        self.assertEqual(_run_gate({"a.py": "a = 1\n" + TWO_LINE_RUN + "b = 2\n"}).returncode, 1)
        self.assertEqual(_run_gate({"a.py": 's = """\n' + SLASH_RUN + '"""\n'}).returncode, 0)

    def test_generated_and_vendored_native_files_are_skipped(self):
        files = {
            "linux/flutter/generated_plugin_registrant.cc": SLASH_RUN,
            "windows/flutter/generated_plugin_registrant.h": SLASH_RUN,
            "macos/Flutter/GeneratedPluginRegistrant.swift": SLASH_RUN,
            "linux/runner/ext-idle-notify-v1-protocol.h": SLASH_RUN,
        }
        self.assertEqual(_run_gate(files).returncode, 0)

    def test_the_allowlist_holds_a_native_file_at_its_count(self):
        body = "let a = 1\n" + SLASH_RUN + "let b = 2\n"
        self.assertEqual(_run_gate({"a.swift": body}, "a.swift 1\n").returncode, 0)
        self.assertEqual(_run_gate({"a.swift": body + SLASH_RUN}, "a.swift 1\n").returncode, 1)


if __name__ == "__main__":
    unittest.main()
