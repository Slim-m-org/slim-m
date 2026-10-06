# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Pins the license-text classifier in scripts/check-dart-licenses.py."""
import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-dart-licenses.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("check_dart_licenses", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BSD_STEM = (
    "Redistribution and use in source and binary forms, with or without\n"
    "modification, are permitted provided that the following conditions are met:\n"
)
SOURCE_CLAUSE = "1. Redistributions of source code must retain the above copyright notice.\n"
BINARY_CLAUSE = (
    "2. Redistributions in binary form must reproduce the above copyright\n"
    "   notice in the documentation.\n"
)
ADVERTISING_CLAUSE = (
    "3. All advertising materials mentioning features or use of this software\n"
    "   must display the following acknowledgement.\n"
)
ENDORSE_CLAUSE = (
    "Neither the name of the copyright holder nor the names of its\n"
    "contributors may be used to endorse or promote products derived from\n"
    "this software without specific prior written permission.\n"
)

BSD_1 = BSD_STEM + SOURCE_CLAUSE
BSD_2 = BSD_STEM + SOURCE_CLAUSE + BINARY_CLAUSE
BSD_3 = BSD_2 + "3. " + ENDORSE_CLAUSE
BSD_4 = BSD_2 + ADVERTISING_CLAUSE + "4. " + ENDORSE_CLAUSE

MIT = (
    "Permission is hereby granted, free of charge, to any person obtaining a copy\n"
    "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND.\n"
)
ISC = (
    "Permission to use, copy, modify, and/or distribute this software for any purpose\n"
    "provided that the above copyright notice and this permission notice appear.\n"
)
ZERO_BSD = "Permission to use, copy, modify, and/or distribute this software for any purpose.\n"


class ClassifyTest(unittest.TestCase):
    def setUp(self):
        self.classify = _load_module().classify

    def test_each_bsd_variant_is_told_apart(self):
        self.assertEqual(self.classify(BSD_1), "BSD-1-Clause")
        self.assertEqual(self.classify(BSD_2), "BSD-2-Clause")
        self.assertEqual(self.classify(BSD_3), "BSD-3-Clause")

    def test_bsd4_is_not_read_as_an_allowed_license(self):
        self.assertNotIn(self.classify(BSD_4), ("BSD-3-Clause", "BSD-2-Clause", "BSD-1-Clause"))

    def test_permissive_markers(self):
        self.assertEqual(self.classify("Apache License\nVersion 2.0, January 2004"), "Apache-2.0")
        self.assertEqual(self.classify("Mozilla Public License Version 2.0"), "MPL-2.0")
        self.assertEqual(self.classify("Creative Commons Legal Code\nCC0 1.0"), "CC0-1.0")
        self.assertEqual(
            self.classify("This is free and unencumbered software released into the public domain."),
            "Unlicense",
        )
        self.assertEqual(self.classify("Boost Software License - Version 1.0"), "BSL-1.0")
        self.assertEqual(self.classify(MIT), "MIT")
        self.assertEqual(self.classify(ISC), "ISC")
        self.assertEqual(self.classify(ZERO_BSD), "0BSD")

    def test_gnu_family_is_matched_on_the_title_block(self):
        self.assertEqual(self.classify("GNU General Public License\nVersion 3, 29 June 2007"), "GPL-3.0-only")
        self.assertEqual(self.classify("GNU General Public License\nVersion 2, June 1991"), "GPL-2.0-only")
        self.assertEqual(self.classify("GNU Lesser General Public License\nVersion 2.1"), "LGPL-2.1-only")
        self.assertEqual(self.classify("GNU Lesser General Public License\nVersion 3"), "LGPL-3.0-only")
        self.assertEqual(self.classify("GNU Affero General Public License\nVersion 3"), "AGPL-3.0-only")

    def test_gnu_names_deep_in_a_body_do_not_count(self):
        body = "Mozilla Public License Version 2.0\n" + "x " * 400 + "GNU General Public License"
        self.assertEqual(self.classify(body), "MPL-2.0")

    def test_unknown_text_is_not_classified(self):
        self.assertIsNone(self.classify("All rights reserved. Do not copy."))


if __name__ == "__main__":
    unittest.main()
