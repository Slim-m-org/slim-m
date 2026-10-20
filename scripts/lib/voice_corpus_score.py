# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Per-clip scores for a received corpus reel.

A recording of a reel is aligned once; the aligned index signal then says which
clip every received sample belongs to, so anomaly events, loudness over the
reference and ViSQOL can be attributed to a clip and rolled up by category.

usage: voice_corpus_score.py <variant-dir>   (reads <profile>/<who>-rx.wav and clip-<A|B>.*)
Run it with the venv python that has numpy, scipy and onnxruntime (see voice_quality_mos.py).
"""
import json
import os
import sys

import voice_burst_abs as burst_abs
import voice_corpus as corpus
import voice_quality as quality
import voice_quality_align as align
import voice_quality_dsp as dsp
import voice_quality_mos as mos

SENDER = {"vqa": "B", "vqb": "A"}
RATE = dsp.ANALYSIS_RATE
MIN_CHUNK_S = 3.0
CLASSES = ("level_burst", "dropout", "static", "click", "tone", "clipping")


def index_signal(length, spans, rate=RATE):
    """1-based clip number per reference sample, 0 in the gaps between clips."""
    out = [0.0] * length
    for number, span in enumerate(spans, 1):
        for i in range(int(span["start"] * rate), min(length, int(span["end"] * rate))):
            out[i] = float(number)
    return out


def split_by_clip(expected, rec, idx, count):
    """`[(expected chunk, received chunk)]` for each clip number 1..count."""
    chunks = [([], []) for _ in range(count)]
    for e, r, n in zip(expected, rec, idx):
        number = int(round(n))
        if number:
            chunks[number - 1][0].append(e)
            chunks[number - 1][1].append(r)
    return chunks


def clip_number(idx, seconds):
    at = int(seconds * RATE)
    return int(round(idx[at])) if 0 <= at < len(idx) else 0


def count_events(events, idx, count):
    tally = [dict.fromkeys(CLASSES, 0) for _ in range(count)]
    for event in events:
        number = clip_number(idx, event["t"])
        if number and event["class"] in CLASSES:
            tally[number - 1][event["class"]] += 1
    return tally


def score_side(ref, ref_rate, spans, rec, rec_rate, with_visqol=True):
    """Per-clip results for one received recording of a reel."""
    ref16, rec16 = dsp.decimate(ref, ref_rate), dsp.decimate(rec, rec_rate)
    aligned = align.track(ref16, rec16)
    report = quality.analyze(ref, ref_rate, rec, rec_rate, aligned=aligned)
    expected = align.expected_signal(ref16, len(rec16), *aligned)
    idx = align.expected_signal(index_signal(len(ref16), spans), len(rec16), *aligned)
    chunks = split_by_clip(expected, rec16, idx, len(spans))
    counts = count_events(report["events"], idx, len(spans))
    pairs = [(e, r) for e, r in chunks if len(r) >= MIN_CHUNK_S * RATE]
    visqol = iter(mos.visqol_scores(pairs) or []) if with_visqol else iter(())
    clips = {}
    for span, (exp, got), tally in zip(spans, chunks, counts):
        if len(got) < MIN_CHUNK_S * RATE:
            continue
        row = {"seconds": round(len(got) / RATE, 1), "counts": tally,
               **burst_abs.measure(exp, RATE, got, RATE)}
        row["visqol"] = next(visqol, None)
        clips[span["id"]] = row
    return {"similarity": report["similarity"], "gain_db": report["gain_db"],
            "counts": report["counts"], "timing": report["timing"], "clips": clips}


def score_directory(directory):
    """Writes `corpus.json` with every profile and direction scored per clip."""
    refs, spans = {}, {}
    for who in "AB":
        refs[who] = dsp.read_wav(os.path.join(directory, f"clip-{who}.wav"))
        with open(os.path.join(directory, f"clip-{who}.spans.json"), encoding="utf-8") as fh:
            spans[who] = json.load(fh)
    results = {}
    for profile in sorted(os.listdir(directory)):
        folder = os.path.join(directory, profile)
        for who, sender in SENDER.items():
            path = os.path.join(folder, f"{who}-rx.wav")
            if not os.path.exists(path):
                continue
            rec, rate = dsp.read_wav(path)
            ref, ref_rate = refs[sender]
            results.setdefault(profile, {})[who] = score_side(ref, ref_rate, spans[sender], rec, rate)
            print(f"  {profile:16} {who} scored", flush=True)
    with open(os.path.join(directory, "corpus.json"), "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=1)
    return results


if __name__ == "__main__":
    score_directory(sys.argv[1])
