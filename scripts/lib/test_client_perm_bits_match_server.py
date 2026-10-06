# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The client's `Perm` bits are the server's `Permissions` bits, name for name.

The client copy decides what the role editor, the escalation messages and every
`hasPermission` gate show, and its own tests build masks from the same `Perm.*`
constants they check, so a renumbered or mistyped bit on either side passes
everything else.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dart_source import strip_block_comments  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "crates" / "slimm-server" / "src" / "permissions.rs"
CLIENT = ROOT / "client" / "packages" / "app" / "lib" / "src" / "permissions.dart"

RUST_BIT = re.compile(r"pub const ([A-Z][A-Z0-9_]*): Self = Self\(1 << (\d+)\);")
DART_BIT = re.compile(r"static const int (\w+) = 1 << (\d+);")


def strip_rust_comments(text: str) -> str:
    """Blanks `//` and `/* */` comments; Rust lifetimes would fool the Dart scrubber's quote tracking."""
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def camel(name: str) -> str:
    head, *rest = name.lower().split("_")
    return head + "".join(part.capitalize() for part in rest)


def server_bits(source: str) -> dict[str, int]:
    return {
        camel(name): int(shift)
        for name, shift in RUST_BIT.findall(strip_rust_comments(source))
    }


def client_bits(source: str) -> dict[str, int]:
    return {
        name: int(shift)
        for name, shift in DART_BIT.findall(strip_block_comments(source))
    }


def mismatches(server: dict[str, int], client: dict[str, int]) -> list[str]:
    found = []
    for name in sorted(server.keys() | client.keys()):
        if name not in client:
            found.append(f"{name} is 1 << {server[name]} on the server, missing from the client")
        elif name not in server:
            found.append(f"{name} is 1 << {client[name]} on the client, missing from the server")
        elif server[name] != client[name]:
            found.append(f"{name} is 1 << {server[name]} on the server but 1 << {client[name]} on the client")
    return found


class ClientPermBitsMatchServerTest(unittest.TestCase):
    def test_every_bit_matches(self):
        server = server_bits(SERVER.read_text())
        client = client_bits(CLIENT.read_text())
        self.assertGreaterEqual(len(server), 19)
        self.assertEqual(mismatches(server, client), [])

    def test_a_renumbered_bit_is_caught(self):
        server = server_bits("pub const MENTION_EVERYONE: Self = Self(1 << 16);\n")
        client = client_bits("static const int mentionEveryone = 1 << 17;\n")
        self.assertEqual(
            mismatches(server, client),
            ["mentionEveryone is 1 << 16 on the server but 1 << 17 on the client"],
        )

    def test_a_bit_only_one_side_has_is_caught(self):
        server = server_bits("pub const RUN_CODE: Self = Self(1 << 17);\n")
        client = client_bits("static const int viewChannel = 1 << 1;\n")
        self.assertEqual(len(mismatches(server, client)), 2)

    def test_comments_do_not_declare_bits(self):
        server = server_bits("// pub const OLD: Self = Self(1 << 3);\n/// pub const X: Self = Self(1 << 4);\n")
        client = client_bits("/// static const int old = 1 << 3;\n")
        self.assertEqual((server, client), ({}, {}))


if __name__ == "__main__":
    unittest.main()
