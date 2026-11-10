# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How a snapshot's file name splits into surface, state, viewport and theme.

Every suite names its own pictures, so the names are the only thing the bundle
has in common across them. The viewport and theme suffixes are stripped; what
is left is the surface, and the coverage registry (`ui_review_coverage.txt`)
says which leading part of it is the screen and which is a state of that screen.
"""
import re
from dataclasses import dataclass
from pathlib import Path

# Window widths below this are phones: kCompactWidth in design_system/app_metrics.dart.
PHONE_BELOW = 600

# Every key of `viewports` in test/ui_snapshot_support.dart, plus the older bare spellings.
VIEWPORT_TOKENS = (
    "phone-portrait", "phone-landscape", "tablet-portrait", "desktop-narrow",
    "laptop-1280", "full-hd", "compact-599", "compact-600", "expanded-999",
    "expanded-1000", "onboarding-899", "onboarding-900", "stepper-467",
    "stepper-468", "settings-799", "settings-800", "review-desktop", "phone", "tablet", "desktop",
    "mobile",
)
THEME_TOKENS = ("dark", "light", "soft", "forest", "halloween")
_SIZE = r"\d{3,4}(?:x\d{3,4})?"
_ALL = sorted(VIEWPORT_TOKENS + THEME_TOKENS, key=len, reverse=True)
_TOKEN = re.compile(r"(?<![A-Za-z0-9])(" + "|".join(_ALL) + "|" + _SIZE + r")(?![A-Za-z0-9])")
_EXPLICIT_STATE = "--"


def viewport_class(width: float) -> str:
    return "phone" if width < PHONE_BELOW else "desktop"


def _cut(name: str, match: re.Match) -> str:
    """[name] without the token [match], and the separators that joined it."""
    left = name[: match.start()]
    kept = left.rstrip("-_")
    right = name[match.end():].lstrip("-_")
    joiner = left[len(kept):] if kept and right else ""
    return kept + ("--" if "--" in joiner else "-" if joiner else "") + right


def strip_tokens(name: str) -> tuple[str, str | None, str | None]:
    """The name without its viewport and theme tokens, and those tokens.

    The last of each kind is taken wherever it sits: most suites end the name
    with them, some put a state after. A name that would be left empty stays whole.
    """
    found = list(_TOKEN.finditer(name))
    theme = next((m for m in reversed(found) if m.group(1) in THEME_TOKENS), None)
    viewport = next((m for m in reversed(found) if m.group(1) not in THEME_TOKENS), None)
    base = name
    for match in sorted(filter(None, (theme, viewport)), key=lambda m: m.start(), reverse=True):
        base = _cut(base, match)
    if not base:
        return name, None, None
    return base, viewport and viewport.group(1), theme and theme.group(1)


@dataclass(frozen=True)
class Row:
    kind: str
    key: str
    area: str
    names: tuple[str, ...]
    status: str  # covered, excluded or pending
    reason: str = ""


def parse_registry(text: str) -> list[Row]:
    """The rows of `kind|key|area|snapshots`; the last column is a comma list of
    surface names, or `exclude: why` or `pending: why`."""
    rows = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 4 or not all(parts):
            raise ValueError(f"registry line {number}: want kind|key|area|snapshots, got {raw!r}")
        kind, key, area, last = parts
        rows.append(_row(kind, key, area, last, number))
    return rows


_STATUS_WORDS = {"exclude": "excluded", "pending": "pending"}


def _row(kind: str, key: str, area: str, last: str, number: int) -> Row:
    word, _, reason = last.partition(":")
    if word in _STATUS_WORDS:
        if not reason.strip():
            raise ValueError(f"registry line {number}: {word} needs a reason")
        return Row(kind, key, area, (), _STATUS_WORDS[word], reason.strip())
    names = tuple(n.strip() for n in last.split(",") if n.strip())
    return Row(kind, key, area, names, "covered")


def load_registry(path: Path) -> list[Row]:
    return parse_registry(path.read_text(encoding="utf-8")) if path.exists() else []


@dataclass(frozen=True)
class Parsed:
    surface: str
    state: str
    area: str
    viewport_token: str | None
    theme_token: str | None


def parse_name(name: str, rows: list[Row]) -> Parsed:
    """Surface, state and area for one snapshot name.

    A `--` in the base is an explicit surface/state split. Otherwise the longest
    registered surface name that leads the base is the surface and the rest is
    its state; a name nothing registered leads is its own surface.
    """
    base, viewport, theme = strip_tokens(name)
    if _EXPLICIT_STATE in base:
        surface, _, state = base.partition(_EXPLICIT_STATE)
        return Parsed(surface, state.replace(_EXPLICIT_STATE, "-"), _area_of(surface, rows), viewport, theme)
    best = _longest_registered(base, rows)
    if best is None:
        return Parsed(base, "default", _area_of(base, rows), viewport, theme)
    state = base[len(best):].lstrip("-_") or "default"
    return Parsed(best, state, _area_of(best, rows), viewport, theme)


def _longest_registered(base: str, rows: list[Row]) -> str | None:
    best = None
    for row in rows:
        for registered in row.names:
            leads = base == registered or base.startswith((registered + "-", registered + "_"))
            if leads and (best is None or len(registered) > len(best)):
                best = registered
    return best


def _area_of(surface: str, rows: list[Row]) -> str:
    for row in rows:
        if surface in row.names:
            return row.area
    return "unregistered"
