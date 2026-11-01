# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/check-pbxproj-ids.py."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-pbxproj-ids.py"
spec = importlib.util.spec_from_file_location("check_pbxproj_ids", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

A = "A" * 24
B = "B" * 24


class DuplicateIdsTest(unittest.TestCase):
    def test_unique_ids_pass(self):
        text = f"\t\t{A} = {{isa = PBXGroup;}};\n\t\t{B} = {{isa = PBXFileReference;}};\n"
        self.assertEqual(checker.duplicate_ids(text), {})

    def test_one_id_defining_two_objects_is_reported_with_its_lines(self):
        text = f"\t\t{A} = {{isa = PBXGroup;}};\n\t\t{A} = {{isa = PBXNativeTarget;}};\n"
        found = checker.duplicate_ids(text)
        self.assertEqual(list(found), [A])
        self.assertEqual([number for number, _ in found[A]], [1, 2])

    def test_a_multiline_object_is_read_from_the_next_line(self):
        text = f"\t\t{A} = {{\n\t\t\tisa = PBXGroup;\n\t\t}};\n\t\t{A} = {{\n\t\t\tisa = PBXProject;\n\t\t}};\n"
        self.assertEqual(list(checker.duplicate_ids(text)), [A])

    def test_a_dictionary_keyed_by_an_id_is_not_an_object(self):
        text = f"\t\t{A} = {{isa = PBXNativeTarget;}};\n\t\t\t\t{A} = {{\n\t\t\t\t\tCreatedOnToolsVersion = 15;\n\t\t\t\t}};\n"
        self.assertEqual(checker.duplicate_ids(text), {})

    def test_a_reference_after_a_key_is_not_a_definition(self):
        text = f"\t\t{A} = {{isa = PBXGroup;}};\n\t\t\tchildren = ({A});\n\t\t\ttarget = {A};\n"
        self.assertEqual(checker.duplicate_ids(text), {})


class MainTest(unittest.TestCase):
    def _project(self, body):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".pbxproj", delete=False)
        self.addCleanup(Path(tmp.name).unlink)
        tmp.write(body)
        tmp.close()
        return tmp.name

    def test_exit_codes(self):
        good = self._project(f"\t\t{A} = {{isa = PBXGroup;}};\n")
        bad = self._project(f"\t\t{A} = {{isa = PBXGroup;}};\n\t\t{A} = {{isa = PBXProject;}};\n")
        self.assertEqual(checker.main([good]), 0)
        self.assertEqual(checker.main([good, bad]), 1)


if __name__ == "__main__":
    unittest.main()
