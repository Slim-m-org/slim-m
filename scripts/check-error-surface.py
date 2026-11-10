#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A failure caught from the server must not be shown with a SnackBar.

Flags a catch block (`on ApiException` and its siblings, a bare `catch`, or an
inline `.catchError`) that hands its failure to `showAppSnackbar`, and a
`runGuarded` result handed to one in the same function. The surface for such a
failure is `AppErrorState` or `GuardedActionState`; a surface already closed by
the time the request answers goes in `EXCEPTIONS` or `GUARDED_EXCEPTIONS` with
its reason, never to silence a regression.

Reads each file's own text, so there is no list of call sites to go stale. The
history, what each pattern is for and the blind spots are in docs/ci-details.md,
"The error-surface gate".
"""

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from dart_source import strip_block_comments  # noqa: E402

EXCEPTIONS: dict[tuple[str, int], str] = {}

# Keyed by function name so an edit above a site does not un-allow it; each is a closed menu.
_MEMBER_ACTIONS = "client/packages/app/lib/src/features/members/widgets/member_actions.dart"

GUARDED_EXCEPTIONS: dict[tuple[str, str], str] = {
    ("client/packages/app/lib/src/features/channels/screens/channel_message_actions.dart", "_reporting"):
        "a message's context menu has closed before the request answers",
    ("client/packages/app/lib/src/features/channels/screens/channel_message_actions.dart", "saveMessageForLater"):
        "a message's context menu has closed before the request answers",
    ("client/packages/app/lib/src/features/channels/widgets/manage_category_sheet.dart", "confirmAndDeleteCategory"):
        "the header context menu has closed before the request answers",
    ("client/packages/app/lib/src/features/channels/widgets/channel_settings_danger_zone.dart", "confirmAndDeleteChannel"):
        "the channel row's context menu has closed before the request answers",
    (_MEMBER_ACTIONS, "toggleNotificationScheduleAllowedUser"):
        "the member row's context menu has closed before the request answers",
    (_MEMBER_ACTIONS, "messageMember"):
        "the member card has closed before the request answers",
    (_MEMBER_ACTIONS, "callMember"):
        "the member card or call menu has closed before the request answers",
    ("client/packages/app/lib/src/features/channels/widgets/row_menu_notifications.dart", "_say"):
        "a row's context menu has closed before the request answers",
    ("client/packages/app/lib/src/features/members/widgets/safety_actions.dart", "_tell"):
        "block and report run from a menu that has closed before the request answers",
}

EXCEPTIONS_SOURCE = "client/packages/api/lib/src/exceptions.dart"
# Falls back to this alone when EXCEPTIONS_SOURCE is unreadable, e.g. a test's own synthetic repo.
FALLBACK_EXCEPTION_NAMES = ("ApiException",)

BARE_CATCH_HEADER = re.compile(
    r"^(?P<indent>[ \t]*)(?:\}[ \t]*)?catch[ \t]*\([^)]*\)[ \t]*\{[ \t]*$"
)
CATCH_ERROR_TAIL = re.compile(r"\.catchError\([ \t]*\([^)]*\)[ \t]*\{[ \t]*$")
SHOWS_SNACKBAR = re.compile(r"ScaffoldMessenger|SnackBar\(|showAppSnackbar\(")


GUARDED_BINDING = re.compile(r"\b(\w+)\s*=\s*await\s+runGuarded\(")
GUARDED_THEN = re.compile(r"\brunGuarded\((?:.|\n)*?\)\s*\.then\(\(\s*(\w+)\s*\)")
SNACKBAR_CALL = re.compile(r"\bshowAppSnackbar\(")
TOP_LEVEL_HEADER = re.compile(r"^[A-Za-z_@]")
TYPE_HEADER = re.compile(r"^(?:abstract\s+|final\s+|base\s+)*(?:class|mixin|extension|enum)\b")
MEMBER_HEADER = re.compile(r"^ {2}[A-Za-z_]")


def function_start(lines: list[str], index: int) -> int:
    """Index of the line that opens the function containing `lines[index]`.

    A top-level function opens at column 0; a member of a class, mixin or
    extension opens at the nearest column-2 line above. Bodies and parameter
    lists sit deeper, so a nested closure never masquerades as the start.
    """
    top = index
    while top > 0 and not TOP_LEVEL_HEADER.match(lines[top]):
        top -= 1
    if not TYPE_HEADER.match(lines[top]):
        return top
    member = index
    while member > top and not MEMBER_HEADER.match(lines[member]):
        member -= 1
    return member


def call_arguments(text: str, open_paren: int) -> str:
    """The text between the parenthesis at `open_paren` and its match."""
    depth = 0
    for i in range(open_paren, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1 : i]
    return text[open_paren + 1 :]


def guarded_snackbars(source: str):
    """Yields (1-based line, enclosing function name) for each `showAppSnackbar(...)` call
    whose arguments name a variable that a `runGuarded` result in the same
    function was bound to, which is a failure sentence being shown as a
    SnackBar without any `catch` for the other patterns to see.
    """
    lines = source.splitlines()
    for match in SNACKBAR_CALL.finditer(source):
        line = source.count("\n", 0, match.start())
        start = function_start(lines, line)
        head = "\n".join(lines[start : line + 1])
        bound = {m.group(1) for m in GUARDED_BINDING.finditer(head)}
        bound |= {m.group(1) for m in GUARDED_THEN.finditer(head)}
        arguments = call_arguments(source, match.end() - 1)
        for name in sorted(bound):
            if re.search(rf"\b{re.escape(name)}\b", arguments):
                header = re.search(r"\b(\w+)\s*\(", lines[start])
                yield line + 1, header.group(1) if header else ""
                break


def api_exception_names(root: Path) -> list[str]:
    """Every class in `exceptions.dart`'s sealed `ApiException` hierarchy,
    read from its own source so a subtype added there needs no matching edit
    here to stay covered.
    """
    path = root / EXCEPTIONS_SOURCE
    if not path.exists():
        return list(FALLBACK_EXCEPTION_NAMES)
    names = sorted(set(re.findall(r"class (\w*Exception)\b", path.read_text())))
    return names or list(FALLBACK_EXCEPTION_NAMES)


def catch_header_pattern(root: Path) -> re.Pattern[str]:
    """`on api.ApiException` and `on ApiException` alike, and every other
    member of the sealed hierarchy [api_exception_names] reads - the `api.`
    prefix is only ever a convention some callers use, never something the
    type itself requires.
    """
    names = "|".join(re.escape(name) for name in api_exception_names(root))
    return re.compile(
        rf"^(?P<indent>[ \t]*)(?:\}}[ \t]*)?on[ \t]+(?:api\.)?(?:{names})\b"
        r"(?:[ \t]+catch\b[^{]*)?[ \t]*\{[ \t]*$"
    )


def header_indent(line: str, catch_header: re.Pattern[str]) -> str | None:
    for pattern in (catch_header, BARE_CATCH_HEADER):
        match = pattern.match(line)
        if match:
            return match.group("indent")
    if CATCH_ERROR_TAIL.search(line):
        return line[: len(line) - len(line.lstrip(" \t"))]
    return None


def catch_blocks(lines: list[str], catch_header: re.Pattern[str]):
    """Yields (1-based header line, body lines) for each caught-exception block.

    An `on (api.)?ApiException catch { ... }` header (prefixed or bare, see
    [catch_header_pattern]), a bare `catch (e) { ... }` one, or a Future's own
    `.catchError((e) { ... })`. The block's end is the next line, at the
    header's indentation or less, that opens with `}`.
    """
    for i, line in enumerate(lines):
        indent = header_indent(line, catch_header)
        if indent is None:
            continue
        body: list[str] = []
        j = i + 1
        while j < len(lines):
            candidate = lines[j]
            stripped = candidate.lstrip()
            current_indent = candidate[: len(candidate) - len(stripped)]
            if stripped.startswith("}") and len(current_indent) <= len(indent):
                break
            body.append(candidate)
            j += 1
        yield i + 1, body


def main() -> int:
    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    )
    files = subprocess.run(
        ["git", "ls-files", "--", "client/packages/app/lib/*.dart"],
        capture_output=True, text=True, check=True, cwd=root,
    ).stdout.splitlines()
    if not files:
        print("::error::no files matched client/packages/app/lib/*.dart; the gate is not reading anything")
        return 1

    catch_header = catch_header_pattern(root)
    checked = 0
    offenders: list[str] = []
    for rel in files:
        file_checked, file_offenders = scan_file(rel, (root / rel).read_text(), catch_header)
        checked += file_checked
        offenders += file_offenders

    if checked == 0:
        print("::error::no caught-exception blocks found anywhere; the gate is not reading anything")
        return 1

    report(offenders)
    print(f"error surface: {checked} catch block(s) checked in {len(files)} files, {len(offenders)} offender(s)")
    return 1 if offenders else 0


def scan_file(rel: str, text: str, catch_header) -> tuple[int, list[str]]:
    """How many guarded calls and catch blocks [rel] has, and which show a SnackBar."""
    source = strip_block_comments(text)
    checked = len(GUARDED_BINDING.findall(source)) + len(GUARDED_THEN.findall(source))
    offenders = [
        f"{rel}:{lineno}:{function}"
        for lineno, function in guarded_snackbars(source)
        if (rel, function) not in GUARDED_EXCEPTIONS
    ]
    for lineno, body in catch_blocks(source.splitlines(), catch_header):
        checked += 1
        shows = any(SHOWS_SNACKBAR.search(candidate) for candidate in body)
        if shows and (rel, lineno) not in EXCEPTIONS:
            offenders.append(f"{rel}:{lineno}:")
    return checked, offenders


def report(offenders: list[str]) -> None:
    for offender in offenders:
        path, lineno, function = offender.split(":")
        if function:
            where = "GUARDED_EXCEPTIONS"
            entry = f'("{path}", "{function}"): "why",'
            what = "a failure sentence from runGuarded is shown with a SnackBar here"
        else:
            where = "EXCEPTIONS"
            entry = f'("{path}", {lineno}): "why",'
            what = "a caught failure is shown with a SnackBar here"
        print(
            f"::error file={path},line={lineno}::{what}; use "
            "GuardedActionState/AppErrorState instead (see run_guarded.dart's "
            "own doc comment), or if this surface has genuinely already closed "
            f"by the time the request answers, add '{entry}' to {where} in "
            "scripts/check-error-surface.py"
        )


if __name__ == "__main__":
    sys.exit(main())
