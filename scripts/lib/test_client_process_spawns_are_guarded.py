# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Client code that starts a process must be desktop-only, by path or by name.

iOS cannot start one, and a `chmod` in the database migration stranded every
existing iOS install; `docs/decisions/0042-encrypt-local-database.md` has it.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dart_source import strip_block_comments  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SPAWN = re.compile(r"\bProcess\s*\.\s*(run|runSync|start)\b")

# Files outside a `desktop/` directory that may spawn, and what keeps a phone out.
GUARDED = {
    "client/packages/data/lib/src/connection/encrypted_database.dart":
        "_narrowsMode: linux and macos only",
    "client/packages/platform/lib/src/autostart_io.dart":
        "hostAutostart builds the reg.exe backend on windows only, and returns null on a phone",
    "client/packages/platform/lib/src/game_source_io.dart":
        "createGameSource returns null off linux, windows and macos",
    "client/packages/platform/lib/src/persistent_key_store.dart":
        "FileKeyStore is the linux backend; every other host uses SecureKeyStore",
}


def spawns(source: str) -> bool:
    """Whether Dart source starts a process, comments aside."""
    return bool(SPAWN.search(strip_block_comments(source)))


def spawning_files() -> set[str]:
    found = set()
    for path in (ROOT / "client").rglob("*.dart"):
        rel = path.relative_to(ROOT).as_posix()
        if "/lib/" not in rel or "/build/" in rel or "/.dart_tool/" in rel:
            continue
        if spawns(path.read_text()):
            found.add(rel)
    return found


class ClientProcessSpawnsAreGuardedTest(unittest.TestCase):
    def test_a_spawn_outside_desktop_is_named_with_its_guard(self):
        loose = {f for f in spawning_files() if "/desktop/" not in f}
        self.assertEqual(
            sorted(loose - set(GUARDED)),
            [],
            "these start a process and a phone build can reach them; move the "
            "code under a desktop/ directory, or guard it by platform and add "
            "it to GUARDED with what the guard is",
        )

    def test_no_entry_outlives_its_spawn(self):
        self.assertEqual(sorted(set(GUARDED) - spawning_files()), [])

    def test_a_comment_that_mentions_a_spawn_is_not_one(self):
        self.assertFalse(spawns("// Process.run('chmod') used to live here\n"))
        self.assertTrue(spawns("final r = Process.runSync('chmod', []);\n"))


if __name__ == "__main__":
    unittest.main()
