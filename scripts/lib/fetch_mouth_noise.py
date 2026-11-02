# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Builds the mouth and desk noise clips from mouth_noise_manifest.json; no audio lives in the repo.
usage: fetch_mouth_noise.py [--out DIR] [--only id,id]
Each source is downloaded once into DIR/../cache and checked against the manifest's sha256 (a mismatch is an error: the upstream file changed), then cut to the manifest's `max_seconds` after trimming leading and trailing silence, resampled to 48 kHz mono with ffmpeg and peak-normalised.
The default DIR is ~/.slimm-scratch/tmp/mouth-noise/clips; the voice transients scenario reads it, or E2E_TRANSIENT_CLIPS.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

import voice_quality_dsp as dsp

MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mouth_noise_manifest.json")
DEFAULT_OUT = os.path.expanduser("~/.slimm-scratch/tmp/mouth-noise/clips")
AGENT = "slimm-voice-corpus/1.0 (https://github.com/Slim-m-org)"
ALLOWED_HOSTS = ("cdn.freesound.org",)
SILENCE_DB = -50
RATE = 48_000


def load_manifest(path=MANIFEST):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def problems(manifest):
    """Why a manifest cannot be built: a missing field, a licence that is not CC0, or a URL off the allowed hosts."""
    out = []
    seen = set()
    for clip in manifest.get("clips", []):
        name = clip.get("id", "?")
        for field in ("id", "kind", "description", "licence", "attribution", "page", "url", "sha256"):
            if not clip.get(field):
                out.append(f"{name}: missing {field}")
        if clip.get("licence") != "CC0":
            out.append(f"{name}: licence {clip.get('licence')!r} is not CC0")
        host = urllib.parse.urlsplit(clip.get("url", "")).hostname or ""
        if urllib.parse.urlsplit(clip.get("url", "")).scheme != "https" or host not in ALLOWED_HOSTS:
            out.append(f"{name}: only https downloads from {', '.join(ALLOWED_HOSTS)} are allowed")
        if name in seen:
            out.append(f"{name}: duplicate id")
        seen.add(name)
    return out


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(clip, cache):
    """The cached source for `clip`, downloaded once and checked against the manifest's sha256."""
    os.makedirs(cache, exist_ok=True)
    target = os.path.join(cache, clip["sha256"][:16] + os.path.splitext(urllib.parse.urlsplit(clip["url"]).path)[1])
    if not os.path.exists(target):
        request = urllib.request.Request(clip["url"], headers={"User-Agent": AGENT})
        with urllib.request.urlopen(request, timeout=60) as response, open(target + ".part", "wb") as fh:
            fh.write(response.read())
        os.replace(target + ".part", target)
    got = sha256_of(target)
    if got != clip["sha256"]:
        os.remove(target)
        raise RuntimeError(f"{clip['id']}: sha256 {got} does not match the manifest, the upstream file changed")
    return target


def convert(source, out_path, max_seconds):
    """48 kHz mono 16-bit, silence trimmed at both ends, cut to `max_seconds`."""
    trim = (f"silenceremove=start_periods=1:start_threshold={SILENCE_DB}dB:start_silence=0.1,"
            f"areverse,silenceremove=start_periods=1:start_threshold={SILENCE_DB}dB:start_silence=0.1,areverse")
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", source, "-af", trim,
                    "-t", str(max_seconds), "-ac", "1", "-ar", str(RATE), "-sample_fmt", "s16", out_path], check=True)


def normalise(path, peak_dbfs):
    samples, rate = dsp.read_wav(path)
    top = max((abs(v) for v in samples), default=0.0)
    if not top:
        raise RuntimeError(f"{path} is silent")
    gain = 10 ** (peak_dbfs / 20) / top
    dsp.write_wav(path, [v * gain for v in samples], rate)
    return len(samples) / rate


def build(manifest, out_dir, only=None):
    found = problems(manifest)
    if found:
        raise SystemExit("\n".join(found))
    os.makedirs(out_dir, exist_ok=True)
    cache = os.path.join(os.path.dirname(os.path.abspath(out_dir)), "cache")
    rows = []
    for clip in manifest["clips"]:
        if only and clip["id"] not in only:
            continue
        source = fetch(clip, cache)
        out_path = os.path.join(out_dir, f"{clip['id']}.wav")
        convert(source, out_path, manifest["max_seconds"])
        seconds = normalise(out_path, manifest["peak_dbfs"])
        rows.append((clip["id"], clip["kind"], seconds))
        print(f"  {clip['id']:22} {clip['kind']:10} {seconds:5.1f} s")
    return rows


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--only", default="")
    args = parser.parse_args(argv)
    only = {o for o in args.only.split(",") if o}
    rows = build(load_manifest(), args.out, only)
    print(f"{len(rows)} clips in {args.out}")


if __name__ == "__main__":
    main(sys.argv[1:])
