# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The real-speech corpus the voice harness plays: manifest rules, levels, mixes and reels.

The manifest (voice_corpus_manifest.json) lists openly licensed clips; no audio is
committed. fetch_voice_corpus.py builds one WAV per clip from it. The harness
(e2e_voice_quality.py) joins a speaker's clips into one looping "reel" and
records where each clip sits, so a received recording can be scored per clip.
"""
import json
import math
import os

import voice_quality_dsp as dsp

RATE = 48_000
FRAME_S = 0.02
ACTIVE_WINDOW_DB = 30.0
PEAK_CEILING_DB = -1.0
REEL_GAP_S = 1.0
MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "voice_corpus_manifest.json")
ALLOWED_LICENCES = ("Public domain", "CC0", "CC BY 3.0", "CC BY 4.0", "CC BY-SA 4.0")
CATEGORIES = ("low-voice", "high-voice", "accent", "non-english", "monologue", "fast", "slow",
              "soft", "loud", "laughter", "singing", "humming", "crosstalk",
              "speech-over-music", "breaths")
REQUIRED = ("id", "category", "reel", "description", "licence", "attribution", "page",
            "layers", "level_dbfs")


def load_manifest(path=MANIFEST):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def validate(manifest):
    """Human-readable problems with a manifest; empty when it is usable."""
    problems, seen = [], set()
    for clip in manifest.get("clips", []):
        name = clip.get("id", "?")
        problems += [f"{name}: missing {k}" for k in REQUIRED if k not in clip]
        if name in seen:
            problems.append(f"{name}: duplicate id")
        seen.add(name)
        if clip.get("licence") not in ALLOWED_LICENCES:
            problems.append(f"{name}: licence {clip.get('licence')!r} is not allowed")
        if clip.get("category") not in CATEGORIES:
            problems.append(f"{name}: unknown category {clip.get('category')!r}")
        if clip.get("reel") not in ("A", "B"):
            problems.append(f"{name}: reel must be A or B")
        for layer in clip.get("layers", []):
            for part in layer.get("parts", []):
                if len(part.get("sha256", "")) != 64:
                    problems.append(f"{name}: a part has no sha256")
                if not part.get("url"):
                    problems.append(f"{name}: a part has no url")
    covered = {c.get("category") for c in manifest.get("clips", [])}
    problems += [f"no clip for category {c}" for c in CATEGORIES if c not in covered]
    return problems


def frame_db(samples, rate=RATE):
    step = int(FRAME_S * rate)
    return [10 * math.log10(max(sum(v * v for v in samples[i:i + step]) / step, 1e-12))
            for i in range(0, len(samples) - step + 1, step)]


def active_rms_db(samples, rate=RATE):
    """Power-mean level of the frames within ACTIVE_WINDOW_DB of the loudest one."""
    levels = frame_db(samples, rate)
    if not levels:
        return dsp.FLOOR_DB
    floor = max(levels) - ACTIVE_WINDOW_DB
    live = [10 ** (v / 10) for v in levels if v >= floor]
    return 10 * math.log10(sum(live) / len(live))


def peak_db(samples):
    top = max((abs(v) for v in samples), default=0.0)
    return 20 * math.log10(top) if top > 0 else dsp.FLOOR_DB


def normalise(samples, level_dbfs, rate=RATE):
    """`(scaled samples, gain dB, limited)`: active speech at `level_dbfs` unless the peak would pass the ceiling."""
    gain = level_dbfs - active_rms_db(samples, rate)
    limited = peak_db(samples) + gain > PEAK_CEILING_DB
    if limited:
        gain = PEAK_CEILING_DB - peak_db(samples)
    scale = 10 ** (gain / 20)
    return [v * scale for v in samples], round(gain, 2), limited


def concat(chunks, gap_s, rate=RATE):
    out = []
    for i, chunk in enumerate(chunks):
        if i:
            out += [0.0] * int(gap_s * rate)
        out += chunk
    return out


def mix(layers, rate=RATE):
    """Sum `(samples, offset_s, gain_db)` layers into one signal as long as the latest end."""
    length = max((int(off * rate) + len(s) for s, off, _ in layers), default=0)
    out = [0.0] * length
    for samples, offset, gain_db in layers:
        scale, start = 10 ** (gain_db / 20), int(offset * rate)
        for i, v in enumerate(samples):
            out[start + i] += v * scale
    return out


def reel_ids(manifest, who):
    return [c["id"] for c in manifest["clips"] if c["reel"] == who]


def build_reel(clips, gap_s=REEL_GAP_S, rate=RATE):
    """`(samples, spans)` of `[(id, samples)]` joined by silence; spans are seconds into the reel."""
    out, spans = [], []
    for name, samples in clips:
        out += [0.0] * int(gap_s * rate)
        spans.append({"id": name, "start": round(len(out) / rate, 3),
                      "end": round((len(out) + len(samples)) / rate, 3)})
        out += samples
    out += [0.0] * int(gap_s * rate)
    return out, spans


def quietest_cut(levels, near, radius):
    """Frame index of the quietest frame within `radius` frames of `near`."""
    low, high = max(1, near - radius), min(len(levels) - 1, near + radius)
    return min(range(low, high + 1), key=lambda i: levels[i])


def gapped(samples, chunk_s=3.5, gap_s=2.6, rate=RATE):
    """`(samples, spans)`: the clip cut at its quietest points and spread over long gaps.

    The gaps hold the noise events of make_noise_bed.py, and each chunk's start is a
    word onset after quiet, which is what the onset-clipping measure looks for.
    """
    levels = frame_db(samples, rate)
    step, radius = int(FRAME_S * rate), int(0.6 / FRAME_S)
    cuts, at = [0], 0
    ahead = int(chunk_s / FRAME_S)
    while at + ahead + radius < len(levels):
        at = quietest_cut(levels, at + ahead, radius)
        cuts.append(at * step + step // 2)
    cuts.append(len(samples))
    out, spans = [0.0] * rate, []
    for a, b in zip(cuts, cuts[1:]):
        chunk = samples[a:b]
        if len(chunk) < 0.5 * rate:
            continue
        spans.append((len(out) / rate, (len(out) + len(chunk)) / rate))
        out += chunk + [0.0] * int(gap_s * rate)
    return out, spans


def corpus_dir():
    """The folder of built clips when E2E_VQ_CORPUS is set, else None.

    A set but incomplete folder raises rather than falling back, so a run never
    reports synthetic speech as the real-voice corpus.
    """
    path = os.environ.get("E2E_VQ_CORPUS")
    if not path:
        return None
    if not os.path.isdir(path):
        raise AssertionError(f"E2E_VQ_CORPUS={path} is not a folder; build it with fetch_voice_corpus.py")
    missing = [c["id"] for c in load_manifest()["clips"]
               if not os.path.exists(os.path.join(path, c["id"] + ".wav"))]
    if missing:
        raise AssertionError(f"E2E_VQ_CORPUS={path} is missing {len(missing)} clip(s), e.g. "
                             f"{', '.join(missing[:5])}; run fetch_voice_corpus.py")
    return path


def write_reel(path, who, directory):
    """Writes the speaker's reel to `path` and its spans beside it; returns the seconds."""
    manifest = load_manifest()
    clips = [(n, dsp.read_wav(os.path.join(directory, n + ".wav"))[0])
             for n in reel_ids(manifest, who)]
    samples, spans = build_reel(clips)
    dsp.write_wav(path, samples, RATE)
    with open(path[:-4] + ".spans.json", "w", encoding="utf-8") as fh:
        json.dump(spans, fh, indent=1)
    return len(samples) / RATE
