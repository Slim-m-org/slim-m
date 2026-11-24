#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Guard against a widget touching `ref` or `setState` after an `await`.

A sheet, menu or row that is dismissed while its request is in flight is
unmounted by the time the request answers. `WidgetRef` then throws on any use,
and `setState` throws too, so the redirect, the invalidate or the local store
update that was meant to follow the request is silently skipped. The fix is to
take a `ProviderContainer` (`ProviderScope.containerOf(context, listen: false)`)
or the notifiers needed before the first await, or to check `mounted` first.

Reads each tracked widget `client/packages/app/lib/**/*.dart` file's own text,
comments and strings stripped first, and flags a `ref.<member>` or
`setState(` that follows an `await` in the same function with no `mounted`
check between. Provider bodies are out of scope: their `ref` is a different
object with its own lifetime. `scripts/ref-after-await-allow.txt` lists the
files that still hold one, each at a ceiling count that only goes down. The
format and history are in docs/ci-details.md, "The ref-after-await gate".
"""

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from dart_source import strip_block_comments  # noqa: E402

ALLOWLIST_PATH = Path(__file__).resolve().parent / "ref-after-await-allow.txt"
SCOPE_PREFIX = "client/packages/app/lib/"
NON_WIDGET_DIRS = ("/providers/", "/sync/", "/push/")
WIDGET_BASE = re.compile(
    r"\b(?:WidgetRef|ConsumerState|ConsumerWidget|StatefulWidget|StatelessWidget)\b"
)
TOKEN = re.compile(
    r";|\{|\}|\bawait\b|\bmounted\b|\breturn\b|\bthrow\b"
    r"|(?<![\w.$])ref\s*\.\s*(?!(?:mounted|context)\b)\w+|\bsetState\s*\("
)
CONTROL_KEYWORDS = {"if", "for", "while", "switch", "catch"}
ASYNC_BODY = re.compile(r"\basync\*?\s*$|\bsync\*\s*$")


def load_allowlist(path: Path) -> dict[str, int]:
    """Each listed path mapped to how many uses it may still hold.

    A ceiling, not a blanket pass, and a count rather than a line number so an
    edit above a use does not move it. `N` after the path sets it; omitted, it is one.
    """
    allowed: dict[str, int] = {}
    for line in path.read_text().splitlines():
        entry = line.split("#", 1)[0].strip()
        if not entry:
            continue
        parts = entry.split()
        allowed[parts[0]] = int(parts[1]) if len(parts) > 1 else 1
    return allowed


def in_scope(rel: str, source: str) -> bool:
    """A widget file under the app package, outside the provider layers."""
    return (
        rel.startswith(SCOPE_PREFIX)
        and rel.endswith(".dart")
        and not rel.endswith(".g.dart")
        and not any(part in rel for part in NON_WIDGET_DIRS)
        and WIDGET_BASE.search(source) is not None
    )


class _Function:
    """One function body: whether an await has completed and no mounted check followed."""

    def __init__(self, is_async: bool = False) -> None:
        self.is_async = is_async
        self.awaited = False
        self.pending = False

    def settle(self) -> None:
        if self.pending:
            self.awaited, self.pending = True, False


class _Block:
    """A `{` frame: the function it belongs to, and what to restore if it returns."""

    def __init__(self, function: _Function, is_function: bool, awaited_before: bool) -> None:
        self.function = function
        self.is_function = is_function
        self.awaited_before = awaited_before
        self.start = 0


def _opens_function(text: str, brace: int) -> bool | None:
    """True for a closure or method body, False for a control block or literal.

    None marks an `async` body, which is a function whose awaits count.
    """
    before = text[:brace].rstrip()
    if ASYNC_BODY.search(before):
        return None
    if not before.endswith(")"):
        return False
    depth, i = 0, len(before) - 1
    while i >= 0:
        if before[i] == ")":
            depth += 1
        elif before[i] == "(":
            depth -= 1
            if depth == 0:
                break
        i -= 1
    word = re.search(r"(\w+)\s*$", before[:i])
    return (word.group(1) if word else "") not in CONTROL_KEYWORDS


def _ends_by_leaving(body: str) -> bool:
    """Whether a block's last statement is a `return` or `throw`."""
    body = body.rstrip()
    if not body.endswith(";"):
        return False
    inner = body[:-1]
    cut = max(inner.rfind(";"), inner.rfind("{"), inner.rfind("}"))
    return re.match(r"\s*(?:return|throw)\b", inner[cut + 1 :]) is not None


def uses_after_await(source: str) -> list[int]:
    """The 1-based lines of each `ref` or `setState` use that follows an await.

    An await counts once its statement ends, so `await ref.read(x)` is clean
    and the statement after it is not. A `mounted` token clears it, and a block
    that ends in `return` or `throw` leaves the state as it found it.
    """
    text = strip_block_comments(source, blank_strings=True)
    top = _Function()
    stack: list[_Block] = []
    hits: list[int] = []
    for match in TOKEN.finditer(text):
        token = match.group(0)
        current = stack[-1].function if stack else top
        if token in (";", "{"):
            current.settle()
        if token == "{":
            kind = _opens_function(text, match.start())
            function = current if kind is False else _Function(is_async=kind is None)
            frame = _Block(function, kind is not False, current.awaited)
            frame.start = match.end()
            stack.append(frame)
        elif token == "}":
            current.settle()
            if stack:
                frame = stack.pop()
                if not frame.is_function and _ends_by_leaving(
                    text[frame.start : match.start()]
                ):
                    frame.function.awaited = frame.awaited_before
        elif token == "await":
            current.pending = current.is_async
        elif token in ("mounted",):
            current.awaited = current.pending = False
        elif token in (";", "return", "throw"):
            continue
        elif current.awaited:
            hits.append(text.count("\n", 0, match.start()) + 1)
    return hits


def offenders_in(sources: dict[str, str], allowed: dict[str, int]) -> list[str]:
    """Which uses are over their file's ceiling, as `path:line`.

    Split out of [main] so it can be tested against files that do not exist.
    """
    offenders: list[str] = []
    for rel, source in sources.items():
        if not in_scope(rel, source):
            continue
        hits = uses_after_await(source)
        offenders.extend(f"{rel}:{lineno}" for lineno in hits[allowed.get(rel, 0) :])
    return offenders


def stale_entries(sources: dict[str, str], allowed: dict[str, int]) -> list[str]:
    """Allowlist entries above what their file now holds, so the list only shrinks."""
    stale: list[str] = []
    for rel, ceiling in allowed.items():
        source = sources.get(rel)
        actual = len(uses_after_await(source)) if source and in_scope(rel, source) else 0
        if ceiling > actual:
            stale.append(f"{rel} lists {ceiling} but holds {actual}")
    return stale


def main() -> int:
    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    )
    files = subprocess.run(
        ["git", "ls-files", "--", f"{SCOPE_PREFIX}**/*.dart"],
        capture_output=True, text=True, check=True, cwd=root,
    ).stdout.splitlines()
    if not files:
        print(f"::error::no files matched {SCOPE_PREFIX}**/*.dart; the gate is not reading anything")
        return 1

    allowed = load_allowlist(ALLOWLIST_PATH)
    sources = {rel: (root / rel).read_text() for rel in files}
    offenders = offenders_in(sources, allowed)
    stale = stale_entries(sources, allowed)

    for offender in offenders:
        path, _, lineno = offender.partition(":")
        print(
            f"::error file={path},line={lineno}::ref or setState used after an await with no "
            "mounted check; the widget can be gone by then. Take a ProviderContainer "
            "(ProviderScope.containerOf(context, listen: false)) or the notifiers you need "
            "before the first await, or check mounted first. If the use is deliberate, "
            f"add '{path} # why' to scripts/ref-after-await-allow.txt (or raise that "
            "entry's count, which is 1 when unwritten)"
        )

    for entry in stale:
        print(f"::error file=scripts/ref-after-await-allow.txt::{entry}; lower or drop the entry")

    print(
        f"ref after await: {len(files)} file(s) read, {len(allowed)} allowlisted, "
        f"{len(offenders)} offender(s), {len(stale)} stale"
    )
    return 1 if offenders or stale else 0


if __name__ == "__main__":
    sys.exit(main())
