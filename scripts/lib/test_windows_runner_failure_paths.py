# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Failure paths of the Windows runner that only build on Windows, checked in its source.

Stdlib only; comments and string literals are blanked before any search.
"""

import re
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[2] / "client/packages/app/windows/runner"
TOKEN = re.compile(r'//[^\n]*|/\*.*?\*/|L?"(?:\\.|[^"\\\n])*"', re.S)


def code(name: str) -> str:
    return TOKEN.sub(lambda m: " " * len(m.group(0)), (RUNNER / name).read_text())


def body(text: str, signature: str) -> str:
    start = text.index(signature)
    depth, i = 0, text.index("{", start)
    begin = i
    while True:
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        i += 1
        if depth == 0:
            return text[begin:i]


class ClipboardPaths(unittest.TestCase):
    def test_a_missing_sink_answers_before_any_thread_starts(self):
        write = body(code("clipboard_image_channel.cpp"), "void WriteImageOffThread(")
        self.assertLess(write.index("sink == nullptr"), write.index("std::thread"))
        self.assertLess(write.index("sink == nullptr"), write.index("new Completion"))

    def test_reading_files_does_not_open_the_clipboard_when_none_are_there(self):
        read = body(code("clipboard_image_channel.cpp"), "bool ReadClipboardFiles(")
        self.assertLess(read.index("IsClipboardFormatAvailable"), read.index("OpenClipboardPatiently"))


class ShortcutRepair(unittest.TestCase):
    def test_quitting_stops_the_repair_instead_of_waiting_it_out(self):
        text = code("app_identity.cpp")
        self.assertIn("g_repair_stop", body(text, "DWORD WINAPI RepairShortcuts("))
        finish = body(text, "void FinishShortcutRepair(")
        self.assertLess(finish.index("g_repair_stop = true"), finish.index("WaitForSingleObject"))
        self.assertNotIn("10000", finish)

    def test_a_stopped_repair_does_not_write_its_done_marker(self):
        worker = body(code("app_identity.cpp"), "DWORD WINAPI RepairShortcuts(")
        self.assertLess(worker.rindex("g_repair_stop"), worker.index("std::ofstream(marker"))


if __name__ == "__main__":
    unittest.main()
