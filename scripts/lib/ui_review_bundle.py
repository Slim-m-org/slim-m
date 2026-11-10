#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Bundles the snapshot PNGs into what a reviewer walks: small images and a manifest.

Reads `build/ui-snapshots/*.png` and the `<name>.json` that `writeSnapshot`
puts beside each, writes `<out>/shots/*.webp` (at most 1600 px wide, quality
80) and `<out>/manifest.json`. Pillow does the encoding; without it the PNGs
are copied as they are. Nothing in the manifest depends on when it ran, so a
re-run on the same pictures rewrites the same bytes.
"""
import argparse
import hashlib
import json
import os
import struct
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ui_review_names import load_registry, parse_name, viewport_class  # noqa: E402

try:
    from PIL import Image
except ImportError:  # the copy fallback below needs no imaging library
    Image = None

ROOT = Path(__file__).resolve().parents[2]
APP = "client/packages/app"
DEFAULT_SRC = ROOT / APP / "build" / "ui-snapshots"
DEFAULT_REGISTRY = ROOT / APP / "test" / "gates" / "ui_review_coverage.txt"
DEFAULT_OUT = Path.home() / ".slimm-scratch" / "ui-review" / "bundle"
PALETTE_THEMES = ("soft", "forest", "halloween")
VIEWPORT_ORDER = {"phone": 0, "desktop": 1}
THEME_ORDER = {"dark": 0, "light": 1}
LOGICAL_PIXEL_RATIO = 2  # writeSnapshot captures at pixelRatio 2


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png_size(path: Path) -> tuple[int, int]:
    """Pixel size from the IHDR chunk, so the fallback needs no imaging library."""
    with path.open("rb") as handle:
        head = handle.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise ValueError(f"{path.name} is not a PNG")
    return struct.unpack(">II", head[16:24])


def read_sidecar(png: Path) -> dict | None:
    path = png.with_suffix(".json")
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return None


def theme_of(token: str | None, brightness: str | None) -> str:
    """The palette a name asks for, else what the render's own Theme said."""
    if token in PALETTE_THEMES:
        return token
    return brightness or token or "unknown"


def _opaque_rgb(image):
    """Drops an alpha channel that is fully opaque, which is every Flutter capture."""
    if image.mode == "RGBA" and image.getchannel("A").getextrema() == (255, 255):
        return image.convert("RGB")
    return image if image.mode in ("RGB", "RGBA") else image.convert("RGBA")


def encode(png: Path, dest_dir: Path, stem: str, max_width: int, quality: int) -> tuple[str, int, int]:
    """Writes the review image and returns its path under the bundle and its pixel size."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    if Image is None:
        target = dest_dir / f"{stem}.png"
        target.write_bytes(png.read_bytes())
        return f"shots/{target.name}", *png_size(png)
    target = dest_dir / f"{stem}.webp"
    with Image.open(png) as image:
        if image.width > max_width:
            image = image.resize(
                (max_width, round(image.height * max_width / image.width)), Image.Resampling.LANCZOS
            )
        image = _opaque_rgb(image)
        image.save(target, "WEBP", quality=quality)
        return f"shots/{target.name}", image.width, image.height


def _previous(out: Path) -> dict:
    try:
        manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {"image": manifest.get("image"), "shots": {s["id"]: s for s in manifest.get("shots", [])}}


def _git(*args: str) -> str:
    try:
        done = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, timeout=30, check=True)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout.strip()


def build_shots(src: Path, out: Path, rows: list, settings: dict, force: bool) -> tuple[list, list]:
    """One manifest entry per PNG in [src], and the warnings met on the way."""
    previous = _previous(out)
    reusable = previous.get("shots", {}) if previous.get("image") == settings and not force else {}
    shots, warnings, to_encode = [], [], []
    for png in sorted(src.glob("*.png")):
        stem = png.stem
        sidecar = read_sidecar(png)
        digest = sha256_of(png)
        if sidecar is None:
            warnings.append(f"{stem}: no sidecar, size and theme guessed")
        parsed = parse_name(stem, rows)
        pixel_width, pixel_height = png_size(png)
        width = (sidecar or {}).get("width", pixel_width / LOGICAL_PIXEL_RATIO)
        height = (sidecar or {}).get("height", pixel_height / LOGICAL_PIXEL_RATIO)
        brightness = (sidecar or {}).get("brightness")
        if parsed.theme_token in ("dark", "light") and brightness and brightness != parsed.theme_token:
            warnings.append(f"{stem}: named {parsed.theme_token} but rendered {brightness}")
        test = (sidecar or {}).get("test")
        shot = {
            "id": stem,
            "surface": parsed.surface,
            "state": parsed.state,
            "area": parsed.area,
            "viewport": viewport_class(width),
            "theme": theme_of(parsed.theme_token, brightness),
            "width": width,
            "height": height,
            "file": "",
            "image_width": 0,
            "image_height": 0,
            "sha256": digest,
            "test": f"{APP}/{test}" if test else "",
            "description": (sidecar or {}).get("description", ""),
        }
        old = reusable.get(stem)
        if old and old.get("sha256") == digest and (out / old["file"]).exists():
            shot.update(file=old["file"], image_width=old["image_width"], image_height=old["image_height"])
        else:
            to_encode.append((shot, png))
        shots.append(shot)
    _encode_all(to_encode, out / "shots", settings)
    return shots, warnings


def _encode_all(jobs: list, dest: Path, settings: dict) -> None:
    """Encodes the pictures with no reusable image, a few at a time: Pillow lets go of the GIL."""
    def one(job):
        shot, png = job
        return encode(png, dest, shot["id"], settings["max_width"], settings["quality"])

    with ThreadPoolExecutor(max_workers=min(4, os.cpu_count() or 1)) as pool:
        for (shot, _), (file, width, height) in zip(jobs, pool.map(one, jobs)):
            shot.update(file=file, image_width=width, image_height=height)


def group_surfaces(shots: list, rows: list) -> list:
    """Shots grouped per surface, areas in registry order and unregistered ones last."""
    area_rank = {}
    for row in rows:
        area_rank.setdefault(row.area, len(area_rank))
    by_surface: dict = {}
    for shot in shots:
        by_surface.setdefault((shot["area"], shot["surface"]), []).append(shot)
    ordered = sorted(by_surface, key=lambda key: (area_rank.get(key[0], len(area_rank)), key[0], key[1]))
    return [
        {"surface": surface, "area": area, "shots": [s["id"] for s in sorted(by_surface[(area, surface)], key=_shot_order)]}
        for area, surface in ordered
    ]


def _shot_order(shot: dict) -> tuple:
    return (
        shot["state"] != "default", shot["state"],
        VIEWPORT_ORDER.get(shot["viewport"], 9), THEME_ORDER.get(shot["theme"], 9), shot["id"],
    )


def coverage(rows: list, shots: list) -> dict:
    """Registered surfaces no picture was taken for, and the rows still waiting for one."""
    produced = {s["surface"] for s in shots}
    missing = sorted({name for row in rows for name in row.names if name not in produced})
    pending = sorted(f"{row.kind}|{row.key}" for row in rows if row.status == "pending")
    unregistered = sorted({s["surface"] for s in shots if s["area"] == "unregistered"})
    return {"missing": missing, "pending": pending, "unregistered": unregistered}


def build_bundle(src: Path, out: Path, registry: Path, settings: dict, force: bool = False, commit: str | None = None) -> dict:
    rows = load_registry(registry)
    shots, warnings = build_shots(src, out, rows, settings, force)
    shots.sort(key=lambda s: (s["area"], s["surface"], *_shot_order(s)))
    kept = {Path(s["file"]).name for s in shots}
    for stale in (out / "shots").glob("*"):
        if stale.name not in kept:
            stale.unlink()
    manifest = {
        "generated_from_commit": commit or _git("rev-parse", "HEAD") or "unknown",
        "dirty": bool(_git("status", "--porcelain", "--untracked-files=no")),
        "image": settings,
        "shots": shots,
        "surfaces": group_surfaces(shots, rows),
        "coverage": coverage(rows, shots),
        "warnings": sorted(warnings),
    }
    out.mkdir(parents=True, exist_ok=True)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def summary(manifest: dict, out: Path) -> str:
    cover = manifest["coverage"]
    lines = [
        f"ui-review: {len(manifest['shots'])} shots over {len(manifest['surfaces'])} surfaces -> {out}",
        f"ui-review: {len(cover['unregistered'])} unregistered surfaces, {len(cover['pending'])} registry rows pending, "
        f"{len(cover['missing'])} registered surfaces with no picture",
    ]
    lines += [f"ui-review: missing {name}" for name in cover["missing"]]
    lines += [f"ui-review: warning {text}" for text in manifest["warnings"]]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--src", type=Path, default=DEFAULT_SRC)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--max-width", type=int, default=1600)
    parser.add_argument("--quality", type=int, default=80)
    parser.add_argument("--commit", default=None)
    parser.add_argument("--force", action="store_true", help="re-encode every image")
    parser.add_argument("--check-coverage", action="store_true", help="fail when a registered surface has no picture")
    args = parser.parse_args(argv)
    if not args.src.is_dir() or not any(args.src.glob("*.png")):
        print(f"ui-review: no PNGs in {args.src}; run scripts/ui-review.sh first", file=sys.stderr)
        return 2
    settings = {"format": "webp" if Image else "png", "max_width": args.max_width, "quality": args.quality}
    manifest = build_bundle(args.src, args.out, args.registry, settings, args.force, args.commit)
    print(summary(manifest, args.out))
    return 1 if args.check_coverage and manifest["coverage"]["missing"] else 0


if __name__ == "__main__":
    sys.exit(main())
