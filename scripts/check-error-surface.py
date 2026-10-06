#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A failure caught from the server is a SnackBar again, three times over.

The nine-specialist audit (2026-07-29) replaced 27 vanishing SnackBars with
persistent `AppErrorState`, on the grounds that a failure which disappears on
its own is a failure nobody saw. A later copy pass found three of them back:
the channel overwrites screen, avatar upload and removal, and the blocked-row
unblock, each caught its own `ApiException` and showed it with a SnackBar
sitting beside a sibling row doing it properly. Nothing gated that; this does.

The distinction is not "is there a SnackBar", which `run_guarded.dart`'s own
doc comment already draws: a surface that has already closed by the time its
request answers (a popover dismissed on tap) has nowhere to put an inline
state, and a SnackBar is genuinely the only option left. Every such call site
in this codebase reaches it through `runGuarded`'s returned sentence, never by
catching `ApiException` itself - so the shape this gate looks for is narrower
and sharper than "any SnackBar near a failure": a widget that catches an API
exception directly and hands the message to `ScaffoldMessenger`/`SnackBar`
rather than to `GuardedActionState`/`AppErrorState`, the two `run_guarded.dart`
actually offers for that failure. That is exactly the shape the three
regressions had, and exactly the shape every fixed site does not.

Reads the `on (api.)?<Something>Exception` blocks straight out of each
`.dart` file's own text rather than keeping a list of what to check: a case
this cannot see is a case that was never written the wrong way in the first
place, so there is nothing to fall out of date.

The `catch (e)` clause is optional in the pattern on purpose: `on
api.ApiException { ... }` with no bound variable is valid Dart, and an
earlier version of this regex required the literal word `catch`, so that
exact shape - unreachable to the interpolation risk `describeApiFailure`
guards against, but just as reachable to a raw `ScaffoldMessenger` call -
sailed through unseen. `presence_controller.dart` alone already has one;
none of them show a SnackBar today, so nothing here was retroactively wrong,
only the gate meant to keep it that way.

`EXCEPTIONS` below is a short, named allowlist rather than a growing file, the
same discipline `type_scale_literal_test.dart` already holds everyone else to:
each entry carries its own one-line why, right beside it. It starts empty,
deliberately - every legitimate SnackBar in this codebase already routes
around a raw catch entirely, through `runGuarded`'s own returned sentence, so
there was no real case to seed it with. Add an entry only for a genuinely new
case of the same shape a popover already gets away with: a surface gone by the
time the request answers, never to silence an actual regression.

A `/* ... */` block comment is blanked out before any of the above ever
runs, because the body-boundary scan below reads "the next line starting
with `}` at or above this indent" to find where a catch block ends, and a
block comment can contain exactly that shape - a stray `}` at column 0, in
a code sample or a note - and stop the scan before it ever reaches a real
`showAppSnackbar(` sitting after it. Reproduced directly: planting a real
violation behind a three-line `/* ... */` comment with a bare `}` in it
made this gate report zero offenders. The stripper is string-aware (a
single/double-quoted `'/*'` like `message_code_langs.dart`'s own
`blockComment` tuple is left alone) so it does not trade that hole for a
new one where a string literal's own `/*`/`*/` characters blank out real
code between them.

A bare `catch (e) { ... }` is checked too, added when three file-picker-open
failures (the emoji upload card, the avatar section, the composer) turned out
to carry this exact shape on a bare catch rather than `on api.*Exception`: a
native picker throwing is not an `ApiException` at all, so the narrower
pattern above could never have seen it. The two patterns cannot overlap - `on
Type catch (e) {` never starts with the literal word `catch`, since `on Type`
sits before it - so this is strictly a wider net, not a replacement.

`SHOWS_SNACKBAR` had never matched a single real call in this codebase: every
site (including the three above) calls `showAppSnackbar`, not the raw
`ScaffoldMessenger`/`SnackBar(` this pattern watched for, so the gate reported
zero offenders whether or not one existed - confirmed by mutating a fixed site
back to its old shape and finding the gate said nothing. `showAppSnackbar` is
now in the pattern too; the two raw shapes stay in it for whatever still
calls them directly, `personal_space_menu.dart`'s success-notice path among
them, which is not itself in scope since it sits outside any catch block.

Not caught, and not a defect in the fix: `composer.dart`'s own picker failure
runs through `attachment_picker.dart`'s shared `runAttachmentPick`, whose
catch block calls back a plain `onPickerFailed()` parameter rather than
naming `showAppSnackbar` in its own body - the call is one file away, at the
composer's own call site. A regex reading one function at a time cannot see
across that indirection; `composer_affordances_test.dart`'s own regression
test is what actually guards that site, mutation-tested the same way.

A Future's own `.catchError((e) { ... })` is the same inline shape as a
`catch` block - the body sits in the same file, on plain text a regex can
still read - and this codebase already uses that idiom (`sync_controller.dart`,
`providers.dart`) for the swallow-and-log case, so it is exactly as reachable
for a SnackBar as `catch` ever was. It carried no pattern until an adversarial
review planted `().catchError((e) { showAppSnackbar(context, e.toString()); })`
in a tracked file and the gate reported zero offenders. A `.catchError` whose
callback is a named function reference rather than an inline literal shares
the composer's own cross-file indirection and is accepted the same way.

The `api.` prefix on `CATCH_HEADER` assumed every caller imports
`slimm_api/api.dart` aliased as `api`; roughly a fifth of this package does
not, and four bare `on ApiException` catches already exist
(`channel_refresher.dart`, `sign_in_screen.dart`) with nothing showing a
SnackBar in them today - but nothing stopped one from starting to. Reproduced
directly: a planted `on ApiException catch (e) { showAppSnackbar(...); }` with
an unaliased import passed this gate silently. The exception names it now
matches, prefixed or bare, are read from `exceptions.dart`'s own sealed
hierarchy rather than hand-kept, the same reason `catch_blocks` reads a file's
own text instead of a maintained list: a future subtype added there is
covered the moment it exists, with nothing here to remember to update.
Deliberately still scoped to that hierarchy rather than any typed exception -
`PlatformException`, `MissingPluginException` and this file's own
`ClipboardImageReadException` stay out of it, matching the module doc's own
line above: this gate is about a failure caught *from the server* becoming a
SnackBar, not every typed catch in the app becoming one.

Left open rather than chased: a multi-line string literal (`'''...'''`)
whose own content happens to include a bare `}` at column zero defeats the
same body-boundary scan the block-comment fix above closed, for the same
reason - `strip_block_comments` is string-aware for a `/*`/`*/` pair, but
the boundary scan itself has no notion of "this line is string content,
not code." Reproduced the same way as the block-comment case. Left alone:
closing it needs a real Dart string-literal tokenizer (triple-quoted, raw,
and interpolated forms all differ), for a shape nothing in this codebase
writes inside a catch block today - the block-comment case was worth
closing because Dart's own doc-comment convention makes `/* */` an
ordinary thing to type; a stray `}`-led line inside a string literal is not.

A failure never has to be *caught* to be surfaced wrongly. `runGuarded` does
the catching itself and hands back a sentence, so `final failure = await
runGuarded(...); showAppSnackbar(context, failure)` has no `catch` in the
caller at all, and every pattern above was blind to it: the member pane's
bulk timeout and bulk remove, the row menu's remove and the profile's eject
all shipped that way past a gate that reported zero offenders. The sentence
that reaches a `showAppSnackbar` from a `runGuarded` result in the same
function is flagged too; see `guarded_snackbars`. A surface that has closed
by the time the request answers (a menu) may still be listed in
`GUARDED_EXCEPTIONS` with its reason, keyed by function name.
"""

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from dart_source import strip_block_comments  # noqa: E402

EXCEPTIONS: dict[tuple[str, int], str] = {}

# Keyed by function name so an edit above a site does not un-allow it; each is a closed menu.
GUARDED_EXCEPTIONS: dict[tuple[str, str], str] = {
    ("client/packages/app/lib/src/screens/channel_message_actions.dart", "_reporting"):
        "a message's context menu has closed before the request answers",
    ("client/packages/app/lib/src/screens/channel_message_actions.dart", "saveMessageForLater"):
        "a message's context menu has closed before the request answers",
    ("client/packages/app/lib/src/widgets/manage_category_sheet.dart", "confirmAndDeleteCategory"):
        "the header context menu has closed before the request answers",
    ("client/packages/app/lib/src/widgets/member_actions.dart", "toggleNotificationScheduleAllowedUser"):
        "the member row's context menu has closed before the request answers",
    ("client/packages/app/lib/src/widgets/member_actions.dart", "messageMember"):
        "the member card has closed before the request answers",
    ("client/packages/app/lib/src/widgets/safety_actions.dart", "_tell"):
        "block and report run from a menu that has closed before the request answers",
}

EXCEPTIONS_SOURCE = "client/packages/api/lib/src/exceptions.dart"
# Falls back to this alone when EXCEPTIONS_SOURCE is unreadable, e.g. a test's own synthetic repo.
FALLBACK_EXCEPTION_NAMES = ("ApiException",)

BARE_CATCH_HEADER = re.compile(
    r"^(?P<indent>[ \t]*)(?:\}[ \t]*)?catch[ \t]*\([^)]*\)[ \t]*\{[ \t]*$"
)
CATCH_ERROR_HEADER = re.compile(
    r"^(?P<indent>[ \t]*)[^\n]*\.catchError\([ \t]*\([^)]*\)[ \t]*\{[ \t]*$"
)
SHOWS_SNACKBAR = re.compile(r"ScaffoldMessenger|SnackBar\(|showAppSnackbar\(")


GUARDED_BINDING = re.compile(r"\b(\w+)\s*=\s*await\s+runGuarded\(")
GUARDED_THEN = re.compile(r"\brunGuarded\((?:.|\n)*?\)\s*\.then\(\(\s*(\w+)\s*\)")
SNACKBAR_CALL = re.compile(r"\bshowAppSnackbar\(")
TOP_LEVEL_HEADER = re.compile(r"^[A-Za-z_@]")
TYPE_HEADER = re.compile(r"^(?:abstract\s+|final\s+|base\s+)*(?:class|mixin|extension|enum)\b")
MEMBER_HEADER = re.compile(r"^  [A-Za-z_]")


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
                header = re.search(r"(\w+)\s*\(", lines[start])
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


def catch_blocks(lines: list[str], catch_header: re.Pattern[str]):
    """Yields (1-based header line, body lines) for each caught-exception block.

    An `on (api.)?ApiException catch { ... }` header (prefixed or bare, see
    [catch_header_pattern]), a bare `catch (e) { ... }` one, or a Future's own
    `.catchError((e) { ... })`; see this file's own module doc for why all
    three are in scope. The block's end is the next line, at the header's
    indentation or less, that opens with `}` - the same section-by-indentation
    technique `hygiene.yml`'s own `section()` helper already uses for a Dart
    brace this project has no AST tool handy for in a plain hygiene step.
    """
    for i, line in enumerate(lines):
        header = (
            catch_header.match(line)
            or BARE_CATCH_HEADER.match(line)
            or CATCH_ERROR_HEADER.match(line)
        )
        if not header:
            continue
        indent = header.group("indent")
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
        source = strip_block_comments((root / rel).read_text())
        lines = source.splitlines()
        checked += len(GUARDED_BINDING.findall(source))
        checked += len(GUARDED_THEN.findall(source))
        for lineno, function in guarded_snackbars(source):
            if (rel, function) not in GUARDED_EXCEPTIONS:
                offenders.append(f"{rel}:{lineno}:{function}")
        for lineno, body in catch_blocks(lines, catch_header):
            checked += 1
            if not any(SHOWS_SNACKBAR.search(candidate) for candidate in body):
                continue
            if (rel, lineno) in EXCEPTIONS:
                continue
            offenders.append(f"{rel}:{lineno}:")

    if checked == 0:
        print("::error::no caught-exception blocks found anywhere; the gate is not reading anything")
        return 1

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

    print(f"error surface: {checked} catch block(s) checked in {len(files)} files, {len(offenders)} offender(s)")
    return 1 if offenders else 0


if __name__ == "__main__":
    sys.exit(main())
