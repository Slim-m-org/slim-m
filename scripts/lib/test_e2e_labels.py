# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Guards e2e_labels.py against drifting out from under the client.

Each constant here is a string this harness clicks or waits for by exact
substring match against the client's accessible names. `L.JOIN_CALL` sat
here for a full release cycle after PR #354 removed the join lobby it named,
and the only symptom was a run failing at "never saw 'Join call'" - a name
that reads as plausible right up until something actually runs it. This test
catches that class of drift in seconds, at unit-test speed, rather than
after the 60-minute stack in scripts/e2e.sh boots.

Every package's `lib` is searched, not just the app's. It was `app/lib` alone,
which quietly narrowed what this could see: a label produced by a design-system
widget - `AppAvatar` composing "<name>, speaking" - lives outside that
directory, so a constant naming it read as stale while being perfectly real.

It reads code only, never comments, and that is load-bearing rather than
tidy. `COMPOSER = "Message #"` went stale on 2026-08-09 when PR #495
correctly stopped a thread's composer rendering a dangling hint, and this
guard stayed green for 46 failing e2e runs because the two doc comments
written to *explain that removal* still carried the string. A guard
satisfied by prose describing a deletion is worse than no guard: it
reports health while the thing it names is gone.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_labels as L  # noqa: E402

_PACKAGES = Path(__file__).resolve().parents[2] / "client" / "packages"

CLIENT_LIBS = sorted(p / "lib" for p in _PACKAGES.iterdir() if (p / "lib").is_dir())

# Fixture content the seed script writes (a channel name, a message body), never a widget's own label.
NOT_A_LABEL = {"TEXT_CHANNEL", "VOICE_CHANNEL", "FIRST_MESSAGE", "REPLY_MESSAGE"}


_COMMENT_LINE = re.compile(r"^\s*//")


def code_only(text):
    """Drop whole-line Dart comments, so a comment cannot satisfy a label.

    Only comment-*only* lines go, never a trailing `//` after real code:
    stripping those would need to know where a string literal ends, and a
    label that shares its line with a comment is still genuinely rendered.
    """
    return "\n".join(
        line for line in text.splitlines() if not _COMMENT_LINE.match(line)
    )


def label_constants():
    for name, value in vars(L).items():
        if name.startswith("_") or name in NOT_A_LABEL:
            continue
        if name.isupper() and isinstance(value, str):
            yield name, value
        elif name.isupper() and isinstance(value, tuple):
            for item in value:
                yield f"{name}[{item}]", item


class LabelsStillExistTest(unittest.TestCase):
    """Every accessible-name constant must appear somewhere in the client."""

    def test_every_label_appears_in_client_source(self):
        sources = [f for lib in CLIENT_LIBS for f in lib.rglob("*.dart")]
        self.assertTrue(sources, f"no .dart files found under {CLIENT_LIBS}")
        contents = [
            code_only(p.read_text(encoding="utf-8", errors="ignore"))
            for p in sources
        ]
        stale = [name for name, value in label_constants()
                 if not any(value in text for text in contents)]
        self.assertEqual(
            stale, [],
            f"e2e_labels.py still names {stale}, but no .dart file in "
            f"any package's lib carries that string any more - the widget was "
            "renamed or removed and the harness needs updating to match")


class InCallIsTheHeaderCountTest(unittest.TestCase):
    """`L.IN_CALL` once matched the idle page's timeline legend, so a join that never happened passed."""

    def test_the_call_header_count_matches(self):
        for text in ("2 in call", "1 in call \u00b7 00:03 \u00b7 4 ms", "lounge\n3 in call"):
            self.assertTrue(L.holds(text, L.IN_CALL), text)

    def test_the_legend_and_settings_prose_do_not(self):
        for text in ("in call", "in call\nsharing\nleft", "Your mic indicator stays on in calls.",
                     "Calling\u2026", "in this call with you"):
            self.assertFalse(L.holds(text, L.IN_CALL), text)

    def test_a_plain_label_is_still_a_case_blind_substring(self):
        self.assertTrue(L.holds("Leave call", "leave CALL"))
        self.assertFalse(L.holds("Leave", "Leave call"))


if __name__ == "__main__":
    unittest.main()
