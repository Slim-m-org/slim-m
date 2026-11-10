# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The client's typing refresh must stay inside the server's typing TTL.

`DEFAULT_TTL` in `crates/slimm-server/src/presence/typing.rs` is how long a typing
state survives without a refresh. `_serverTypingTtlSeconds` in
`client/packages/app/lib/src/features/messages/providers/typing_controller.dart` mirrors it by
hand, and the client's `_refreshEvery` is derived from that mirror at compile
time so there is one number to change on the Dart side.

The mirror itself has no mechanical link back to the Rust constant, which is
what this checks. Lower `DEFAULT_TTL` to reduce lock pressure without reading
one Dart doc comment and every user's typing indicator starts flickering off
mid-sentence - a symptom nobody would attribute to a server-side constant, on
a surface no test renders over time.

Same shape as `test_launch_screen_color_drift.py`, which guards the other
hand-copied cross-language constant in this repository, and a text parse
rather than a real one for the reason that file gives: the hygiene job runs
this suite on a bare runner with no pip install step.
"""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dart_source import strip_block_comments  # noqa: E402
from test_client_perm_bits_match_server import strip_rust_comments  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
SERVER_TYPING = REPO_ROOT / "crates/slimm-server/src/presence/typing.rs"
CLIENT_TYPING = (
    REPO_ROOT
    / "client/packages/app/lib/src/features/messages/providers/typing_controller.dart"
)

SERVER_TTL = re.compile(
    r"pub const DEFAULT_TTL: Duration = Duration::from_secs\((\d+)\)"
)
CLIENT_MIRROR = re.compile(r"const int _serverTypingTtlSeconds = (\d+);")
CLIENT_REFRESH = re.compile(
    r"const Duration _refreshEvery = Duration\(\s*seconds: "
    r"_serverTypingTtlSeconds ~/ (\d+),?\s*\);"
)


def server_code(text: str) -> str:
    return strip_rust_comments(text)


def client_code(text: str) -> str:
    return strip_block_comments(text)


class TypingTtlDriftTest(unittest.TestCase):
    def setUp(self):
        self.server = server_code(SERVER_TYPING.read_text())
        self.client = client_code(CLIENT_TYPING.read_text())

    def _server_ttl(self) -> int:
        match = SERVER_TTL.search(self.server)
        self.assertIsNotNone(
            match,
            f"no DEFAULT_TTL found in {SERVER_TYPING.name}; the declaration "
            "this reads has moved or changed shape, and every assertion here "
            "would otherwise read as vacuous",
        )
        return int(match.group(1))

    def _client_mirror(self) -> int:
        match = CLIENT_MIRROR.search(self.client)
        self.assertIsNotNone(
            match,
            f"no _serverTypingTtlSeconds in {CLIENT_TYPING.name}; if the "
            "mirror was inlined back into _refreshEvery, the coupling this "
            "guards is unguarded again",
        )
        return int(match.group(1))

    def test_the_client_mirror_matches_the_server_constant(self):
        self.assertEqual(
            self._client_mirror(),
            self._server_ttl(),
            "the client's copy of the server's typing TTL has drifted; change "
            "both or the typing indicator flickers off mid-sentence",
        )

    def test_the_refresh_is_derived_and_strictly_inside_the_ttl(self):
        match = CLIENT_REFRESH.search(self.client)
        self.assertIsNotNone(
            match,
            "_refreshEvery is no longer derived from _serverTypingTtlSeconds; "
            "a bare literal there is the thing this gate exists to prevent",
        )
        divisor = int(match.group(1))
        self.assertGreater(divisor, 1, "a divisor of 1 leaves no margin at all")
        refresh = self._client_mirror() // divisor
        self.assertGreater(refresh, 0, "the refresh rounded down to zero")
        self.assertLess(
            refresh,
            self._server_ttl(),
            "the refresh interval is not inside the server's expiry",
        )

    def test_the_patterns_are_not_vacuous(self):
        """A regex that matches nothing would make the checks above pass."""
        self.assertRegex(self.server, SERVER_TTL)
        self.assertRegex(self.client, CLIENT_MIRROR)
        self.assertRegex(self.client, CLIENT_REFRESH)


class CommentedOutDeclarationsTest(unittest.TestCase):
    """A stale value left in a comment must not be the one that is compared."""

    def test_a_commented_out_server_ttl_is_not_read(self):
        source = (
            "// pub const DEFAULT_TTL: Duration = Duration::from_secs(10);\n"
            "/// was `pub const DEFAULT_TTL: Duration = Duration::from_secs(8);`\n"
            "pub const DEFAULT_TTL: Duration = Duration::from_secs(6);\n"
        )
        self.assertEqual(SERVER_TTL.search(server_code(source)).group(1), "6")

    def test_a_commented_out_client_mirror_is_not_read(self):
        source = (
            "// const int _serverTypingTtlSeconds = 10;\n"
            "/// Mirrors `const int _serverTypingTtlSeconds = 8;` on the server.\n"
            "const int _serverTypingTtlSeconds = 6;\n"
        )
        self.assertEqual(CLIENT_MIRROR.search(client_code(source)).group(1), "6")


if __name__ == "__main__":
    unittest.main()
