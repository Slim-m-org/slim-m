# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The client's `InputLimits` are the server's caps, number for number.

A field that lets someone type past the server's cap fails only at submit, and
one that stops short refuses a value the server would take. Both sides are
hand-written, so nothing else notices when one of them moves.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dart_source import strip_block_comments  # noqa: E402
from test_client_perm_bits_match_server import strip_rust_comments  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "crates" / "slimm-server" / "src"
PACKAGES = ROOT / "client" / "packages"
CLIENT = PACKAGES / "api" / "lib" / "src" / "limits.dart"

# Each client limit and the server constant it mirrors, as (file under src, constant).
MIRRORS = {
    "name": ("limits.rs", "MAX_NAME_CHARS"),
    "username": ("limits.rs", "MAX_USERNAME_CHARS"),
    "passwordMin": ("limits.rs", "MIN_PASSWORD_CHARS"),
    "password": ("limits.rs", "MAX_PASSWORD_CHARS"),
    "searchQuery": ("limits.rs", "MAX_QUERY_CHARS"),
    "channelTopic": ("http/channels/channel_validation.rs", "CHANNEL_TOPIC_MAX_CHARS"),
    "spaceDescription": ("store/space_landing.rs", "MAX_SPACE_DESCRIPTION_CHARS"),
    "botPrefix": ("store/bot_commands.rs", "MAX_BOT_PREFIX_LEN"),
    "welcomeMessage": ("store/space_welcome.rs", "MAX_WELCOME_MESSAGE_CHARS"),
    "spaceRules": ("store/member_gate.rs", "MAX_RULES_CHARS"),
    "statusText": ("http/user_status.rs", "STATUS_TEXT_MAX_CHARS"),
    "pronouns": ("http/user_status.rs", "PRONOUNS_MAX_CHARS"),
    "about": ("http/user_status.rs", "ABOUT_MAX_CHARS"),
    "userNote": ("http/user_notes.rs", "MAX_NOTE_CHARS"),
    "message": ("http/messages/message_validation.rs", "MESSAGE_MAX_CHARS"),
    "reportReason": ("store/stamp_reports.rs", "MAX_REASON_CHARS"),
    "pollQuestion": ("store/polls.rs", "MAX_QUESTION_CHARS"),
    "pollOption": ("store/polls.rs", "MAX_OPTION_CHARS"),
    "emojiName": ("emoji.rs", "MAX_NAME_LEN"),
    "roleColors": ("store/roles.rs", "ROLE_COLOR_COUNT"),
    "attachmentsPerMessage": ("store/attachments.rs", "MAX_ATTACHMENTS_PER_MESSAGE"),
    "callNote": ("http/voice/voice_transcript_marks.rs", "MAX_NOTE_CHARS"),
    "screenNote": ("http/ws/signals_screen_annotation.rs", "MAX_ANNOTATION_TEXT_CHARS"),
    "debugLogNote": ("http/debug_logs.rs", "MAX_NOTE_CHARS"),
}

# Further server caps an InputLimits entry also stands for.
ALSO_MIRRORED = {
    "name": [("http/webhooks.rs", "USERNAME_MAX_CHARS")],
}

# Client caps that live outside InputLimits, as (file under client/packages, constant): server side.
STANDALONE = {
    ("design_system/lib/src/custom_theme.dart", "themeNameMaxChars"): ("space_theme.rs", "MAX_NAME_CHARS"),
}

DART_LIMIT = re.compile(r"static const int (\w+) = (\d+);")


def client_limits(source: str) -> dict[str, int]:
    body = strip_block_comments(source)
    start = body.find("abstract final class InputLimits")
    end = body.find("\n}", start)
    return {name: int(value) for name, value in DART_LIMIT.findall(body[start:end])}


def server_constant(source: str, name: str, read_module=None) -> int | None:
    """The constant's value, following one `crate::path::CONST` alias through [read_module]."""
    pattern = re.compile(rf"\bconst {name}: usize = ([\d_]+|crate(?:::\w+)+);")
    found = pattern.search(strip_rust_comments(source))
    if not found:
        return None
    value = found.group(1)
    if not value.startswith("crate::"):
        return int(value.replace("_", ""))
    if read_module is None:
        return None
    *module, constant = value.split("::")[1:]
    return server_constant(read_module("/".join(module) + ".rs"), constant)


def standalone_constant(source: str, name: str) -> int | None:
    found = re.search(rf"\bconst (?:int )?{name} = (\d+);", strip_block_comments(source))
    return int(found.group(1)) if found else None


def mismatches(client: dict[str, int], read_server) -> list[str]:
    found = []
    for name in sorted(client.keys() | MIRRORS.keys()):
        if name not in MIRRORS:
            found.append(f"InputLimits.{name} names no server constant; add it to MIRRORS")
            continue
        path, constant = MIRRORS[name]
        server = read_server(path, constant)
        if name not in client:
            found.append(f"InputLimits.{name} is missing from the client")
        elif server is None:
            found.append(f"{constant} is not a usize constant in {path}")
        elif server != client[name]:
            found.append(f"InputLimits.{name} is {client[name]} but {constant} in {path} is {server}")
        for path, constant in ALSO_MIRRORED.get(name, []):
            server = read_server(path, constant)
            if name in client and server != client[name]:
                found.append(f"InputLimits.{name} is {client[name]} but {constant} in {path} is {server}")
    return found


def standalone_mismatches(read_client, read_server) -> list[str]:
    found = []
    for (path, name), (server_path, constant) in sorted(STANDALONE.items()):
        client, server = read_client(path, name), read_server(server_path, constant)
        if client is None:
            found.append(f"{name} is not an int constant in {path}")
        elif server != client:
            found.append(f"{name} in {path} is {client} but {constant} in {server_path} is {server}")
    return found


def read_real_server(path: str, constant: str) -> int | None:
    return server_constant((SERVER / path).read_text(), constant, lambda module: (SERVER / module).read_text())


def read_real_client(path: str, name: str) -> int | None:
    return standalone_constant((PACKAGES / path).read_text(), name)


class ClientInputLimitsMatchServerTest(unittest.TestCase):
    def test_every_limit_matches_its_server_constant(self):
        client = client_limits(CLIENT.read_text())
        self.assertGreaterEqual(len(client), len(MIRRORS))
        self.assertEqual(mismatches(client, read_real_server), [])

    def test_a_changed_server_cap_is_caught(self):
        client = client_limits(CLIENT.read_text())

        def moved(path, constant):
            return 80 if constant == "MAX_NAME_CHARS" else read_real_server(path, constant)

        self.assertEqual(
            mismatches(client, moved),
            ["InputLimits.name is 64 but MAX_NAME_CHARS in limits.rs is 80"],
        )

    def test_a_drifted_new_client_cap_is_caught(self):
        client = client_limits(CLIENT.read_text())
        for name in ("callNote", "screenNote", "debugLogNote"):
            drifted = {**client, name: client[name] + 1}
            path, constant = MIRRORS[name]
            self.assertEqual(
                mismatches(drifted, read_real_server),
                [f"InputLimits.{name} is {client[name] + 1} but {constant} in {path} is {client[name]}"],
            )

    def test_the_webhook_username_cap_follows_the_name_cap(self):
        self.assertEqual(read_real_server("http/webhooks.rs", "USERNAME_MAX_CHARS"), 64)
        client = client_limits(CLIENT.read_text())

        def moved(path, constant):
            return 80 if constant == "USERNAME_MAX_CHARS" else read_real_server(path, constant)

        self.assertEqual(
            mismatches(client, moved),
            ["InputLimits.name is 64 but USERNAME_MAX_CHARS in http/webhooks.rs is 80"],
        )

    def test_every_standalone_cap_matches_its_server_constant(self):
        self.assertEqual(standalone_mismatches(read_real_client, read_real_server), [])

    def test_a_drifted_theme_name_cap_is_caught(self):
        def drifted(path, name):
            return 41 if name == "themeNameMaxChars" else read_real_client(path, name)

        self.assertEqual(
            standalone_mismatches(drifted, read_real_server),
            [
                "themeNameMaxChars in design_system/lib/src/custom_theme.dart is 41 "
                "but MAX_NAME_CHARS in space_theme.rs is 40"
            ],
        )

    def test_a_limit_with_no_server_constant_is_caught(self):
        found = mismatches({"made_up": 5}, read_real_server)
        self.assertIn("InputLimits.made_up names no server constant; add it to MIRRORS", found)

    def test_a_commented_out_constant_is_not_read(self):
        source = "// const MAX_NAME_CHARS: usize = 99;\npub const MAX_NAME_CHARS: usize = 64;\n"
        self.assertEqual(server_constant(source, "MAX_NAME_CHARS"), 64)
        dart = "abstract final class InputLimits {\n  // static const int name = 99;\n  static const int name = 64;\n}\n"
        self.assertEqual(client_limits(dart), {"name": 64})


    def test_the_profile_batch_size_matches_the_server(self):
        source = strip_block_comments((CLIENT.parent / "client_users.dart").read_text())
        found = re.search(r"\bconst _maxUserIdsPerRequest = (\d+);", source)
        self.assertIsNotNone(found, "_maxUserIdsPerRequest is no longer an int constant in client_users.dart")
        self.assertEqual(int(found.group(1)), read_real_server("http/users.rs", "MAX_USER_BATCH"))


if __name__ == "__main__":
    unittest.main()
