# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Builds the attachment fixtures a seeding run's `send_attachment` picks from.

Split out of `seed_run.py` to keep that file under the review budget.
"""
import os
import random

import seed_media

# Wide, tall, small, a medium "screenshot", then one large photo.
_IMAGE_SPECS = (
    ("seed-banner.png", lambda p, rng: seed_media.gradient_png(
        p, 1600, 360, (27, 111, 145), (216, 88, 55), axis="x")),
    ("seed-poster.png", lambda p, rng: seed_media.gradient_png(
        p, 360, 1600, (88, 180, 216), (33, 33, 46), axis="y")),
    ("seed-icon.png", lambda p, rng: seed_media.checkerboard_png(
        p, 40, 40, (88, 216, 120), (20, 40, 30), cell=5)),
    ("seed-screenshot.png", lambda p, rng: seed_media.rings_png(
        p, 640, 360, (216, 88, 55), (245, 230, 200), ring_width=18)),
    ("seed-large-photo.png", lambda p, rng: seed_media.noise_png(
        p, 2000, 1400, rng)),
)
_PDF_TITLE = "Release notes - overnight sync"
_PDF_LINES = (
    "Fixed the reconnect loop dropping the last few messages.",
    "Added retry with backoff on the push relay client.",
    "Bumped the SQLite busy timeout to 5 seconds.",
    "Known issue: screen share on Wayland still needs a manual source id.",
    "Next up: paginate the report queue past 200 entries.",
)
_LOG_LINES = (
    "2026-08-04T02:11:03Z INFO  slimm_server: listening on 0.0.0.0:8080",
    "2026-08-04T02:11:04Z INFO  slimm_server::db: applied 24 migrations",
    "2026-08-04T02:14:22Z WARN  slimm_server::push: relay unreachable, retrying in 5s",
    "2026-08-04T02:14:27Z INFO  slimm_server::push: relay reachable again",
    "2026-08-04T02:20:11Z INFO  slimm_server::voice: sweep removed 1 stale participant",
)
_ARCHIVE_ENTRIES = (
    ("README.txt", b"Overnight sync notes.\nSee CHANGELOG for details.\n"),
    ("config.json", b'{"retries": 3, "timeout_ms": 5000}\n'),
)


def build(scratch_dir, seed):
    """Every attachment fixture the run may pick from `send_attachment`:
    five PNGs (see `_IMAGE_SPECS`), one PDF, a text log, a zip archive, a
    WAV tone, and - when ffmpeg is on `PATH` - a short real mp4 clip.

    `seed-large-photo.png` is about 8 MiB of noise: a big upload to exercise
    the image path, not a near-limit one, since the default per-upload cap
    (`default_attachment_max_bytes` in `crates/slimm-server/src/config.rs`)
    is 1 GiB.
    Nothing here is a file the server would refuse: see
    `scripts/seed-data.py`'s module doc for the real allowed set, sniffed
    from bytes rather than filename or declared type. Everything but the
    mp4 is stdlib-only and so always present; the mp4 is skipped with a
    printed reason, never a failure, when ffmpeg is not installed.

    `seed` makes the noise image and the wav tone reproducible under
    `--seed`, the same as every other generated fixture and message.
    """
    rng = random.Random(f"{seed}-fixtures")
    fixtures = []
    for filename, build_one in _IMAGE_SPECS:
        path = os.path.join(scratch_dir, filename)
        build_one(path, rng)
        with open(path, "rb") as handle:
            fixtures.append((handle.read(), "image/png", filename))

    pdf_path = os.path.join(scratch_dir, "seed-notes.pdf")
    seed_media.pdf(pdf_path, _PDF_TITLE, _PDF_LINES)
    with open(pdf_path, "rb") as handle:
        fixtures.append((handle.read(), "application/pdf", "seed-notes.pdf"))

    log_path = os.path.join(scratch_dir, "server.log")
    seed_media.plain_text(log_path, _LOG_LINES)
    with open(log_path, "rb") as handle:
        fixtures.append((handle.read(), "text/plain", "server.log"))

    zip_path = os.path.join(scratch_dir, "sync-notes.zip")
    seed_media.zip_archive(zip_path, _ARCHIVE_ENTRIES)
    with open(zip_path, "rb") as handle:
        fixtures.append((handle.read(), "application/zip", "sync-notes.zip"))

    wav_path = os.path.join(scratch_dir, "seed-tone.wav")
    seed_media.wav_tone(wav_path, rng)
    with open(wav_path, "rb") as handle:
        fixtures.append((handle.read(), "audio/wav", "seed-tone.wav"))

    if seed_media.ffmpeg_available():
        mp4_path = os.path.join(scratch_dir, "seed-clip.mp4")
        seed_media.mp4_clip(mp4_path)
        with open(mp4_path, "rb") as handle:
            fixtures.append((handle.read(), "video/mp4", "seed-clip.mp4"))
    else:
        print("seed-data: ffmpeg not on PATH, skipping the video/mp4 fixture")

    return fixtures
