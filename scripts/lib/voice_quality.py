# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Finds what a call did to a known clip: dropouts, clicks, static, stray tones, clipping, drift.

usage: voice_quality.py reference.wav received.wav [--json]

Every detector compares the received audio with what the reference should have
sounded like at that moment, so speech onsets and sweeps are not mistaken for
artefacts. Times are seconds into the received recording.
"""
import json
import math
import statistics
import sys

import voice_quality_align as align
import voice_quality_dsp as dsp

HOP_S = dsp.HOP / dsp.ANALYSIS_RATE
ACTIVE_DB = -45.0
DROPOUT_DROP_DB = 20.0
MIN_RUN_FRAMES = 3
STATIC_FLATNESS = 0.25
STATIC_OVER_REF = 0.15
STATIC_MIN_DB = -55.0
SILENT_REF_DB = -90.0
CLICK_RATIO = 8.0
CLICK_MIN = 0.03
CLICK_OVER_REF = 4.0
TONE_MIN_SECONDS = 0.3
TONE_POWER = 3e-4
TONE_OVER_REF = 100.0
TONE_PEAKINESS = 8.0
BURST_RISE_DB = 4.0
CLIP_LEVEL = 0.99
CLIP_RUN = 3
BAND_EDGES = (2, 4, 6, 8, 11, 14, 18, 23, 29, 36, 45, 56, 70, 88, 110, 138,
              172, 215, 256)


def _frame_db(signal):
    return [dsp.rms_db(signal[s:s + dsp.FRAME]) for s in dsp.frame_starts(len(signal))]


def _flatness(spec):
    band = [p + 1e-12 for p in spec[4:dsp.BINS - 1]]
    mean = sum(band) / len(band)
    return math.exp(sum(math.log(p) for p in band) / len(band)) / mean


def _runs(flags, min_frames, gap=1):
    """`(first, last)` frame spans of consecutive True flags, bridging `gap` misses."""
    spans, start, last, misses = [], None, None, 0
    for i, flag in enumerate(flags):
        if flag:
            if start is None:
                start = i
            last, misses = i, 0
        elif start is not None:
            misses += 1
            if misses > gap:
                spans.append((start, last))
                start = None
    if start is not None:
        spans.append((start, last))
    return [s for s in spans if s[1] - s[0] + 1 >= min_frames]


def _event(kind, first, last, detail):
    return {"class": kind, "t": round(first * HOP_S, 2),
            "dur_ms": round(((last - first) * HOP_S + dsp.FRAME / dsp.ANALYSIS_RATE) * 1000),
            "detail": detail}


def find_clipping(raw, rate):
    """Runs of samples pinned at full scale, merged when within 50 ms of each other."""
    runs, run = [], 0
    for i, v in enumerate(raw):
        if abs(v) >= CLIP_LEVEL:
            run += 1
            continue
        if run >= CLIP_RUN:
            runs.append((i - run, i))
        run = 0
    if run >= CLIP_RUN:
        runs.append((len(raw) - run, len(raw)))
    merged = []
    for start, end in runs:
        if merged and start - merged[-1][1] < 0.05 * rate:
            merged[-1][1:] = [end, merged[-1][2] + 1]
        else:
            merged.append([start, end, 1])
    return [{"class": "clipping", "t": round(s / rate, 3),
             "dur_ms": round((e - s) * 1000 / rate, 1),
             "detail": f"{n} run(s) at full scale"} for s, e, n in merged]


def find_dropouts(rec_db, exp_db, gain):
    flags = [e > ACTIVE_DB and r - gain < e - DROPOUT_DROP_DB
             for r, e in zip(rec_db, exp_db)]
    return [_event("dropout", a, b, f"{exp_db[a]:.0f} dB expected, "
                   f"{statistics.mean(rec_db[a:b + 1]) - gain:.0f} dB heard")
            for a, b in _runs(flags, MIN_RUN_FRAMES)]


def find_level_bursts(rec_db, exp_db, gain):
    flags = [e > ACTIVE_DB and r - gain > e + BURST_RISE_DB
             for r, e in zip(rec_db, exp_db)]
    return [_event("level_burst", a, b, f"+{statistics.mean(rec_db[a:b + 1]) - gain - statistics.mean(exp_db[a:b + 1]):.1f} dB over the reference")
            for a, b in _runs(flags, MIN_RUN_FRAMES)]


def _reference_flatness(spec, level_db):
    """Digital silence has a flat spectrum by construction, so it counts as not noise-like."""
    return 0.0 if level_db < SILENT_REF_DB else _flatness(spec)


def find_static(rec_db, rec_spec, exp_spec, exp_db, gain):
    flags = []
    for r, rs, es, e in zip(rec_db, rec_spec, exp_spec, exp_db):
        if r - gain < STATIC_MIN_DB:
            flags.append(False)
            continue
        flat = _flatness(rs)
        flags.append(flat > STATIC_FLATNESS
                     and flat - _reference_flatness(es, e) > STATIC_OVER_REF)
    return [_event("static", a, b, "noise-like energy the reference lacks")
            for a, b in _runs(flags, MIN_RUN_FRAMES)]


def _peak_blocks(signal):
    d2 = [signal[i] - 2 * signal[i - 1] + signal[i - 2] for i in range(2, len(signal))]
    return [max((abs(v) for v in d2[s:s + dsp.HOP]), default=0.0)
            for s in range(0, len(d2), dsp.HOP)]


def find_clicks(rec, expected, gain):
    scale = 1.0 / gain if gain else 1.0
    peaks = [p * scale for p in _peak_blocks(rec)]
    ref_peaks = _peak_blocks(expected)
    flagged = set()
    for i, p in enumerate(peaks):
        around = peaks[max(0, i - 6):i + 7]
        floor = max(statistics.median(around), 0.002)
        near = max(ref_peaks[max(0, i - 1):i + 2], default=0.0)
        if p > CLICK_RATIO * floor and p > CLICK_MIN and p > CLICK_OVER_REF * near:
            flagged.add(i)
    return [_event("click", a, b, "sample-step transient")
            for a, b in _runs([i in flagged for i in range(len(peaks))], 1, gap=0)]


def _tone_candidate(rs, es, power_floor):
    best, best_excess = None, TONE_OVER_REF
    for k in range(3, dsp.BINS - 3):
        p = rs[k]
        if p < power_floor or p < max(rs[k - 3:k + 4]):
            continue
        excess = p / (max(es[k - 2:k + 3]) + 1e-9)
        if excess <= best_excess:
            continue
        if p > TONE_PEAKINESS * statistics.median(rs[max(0, k - 12):k + 13]):
            best, best_excess = k, excess
    return best


def find_tones(rec_spec, exp_spec, gain):
    power_floor = TONE_POWER * gain * gain
    cands = [_tone_candidate(rs, es, power_floor)
             for rs, es in zip(rec_spec, exp_spec)]
    events, i = [], 0
    while i < len(cands):
        k = cands[i]
        if k is None:
            i += 1
            continue
        last, misses, j = i, 0, i + 1
        while j < len(cands) and misses <= 2:
            other = cands[j]
            if other is not None and abs(other - k) <= 2:
                last, misses = j, 0
            else:
                misses += 1
            j += 1
        if (last - i) * HOP_S >= TONE_MIN_SECONDS:
            hz = k * dsp.ANALYSIS_RATE / dsp.FRAME
            events.append(_event("tone", i, last, f"{hz:.0f} Hz not in the reference"))
        i = last + 1
    return events


def similarity(rec_spec, exp_spec, exp_db):
    scores = []
    for rs, es, e in zip(rec_spec, exp_spec, exp_db):
        if e <= ACTIVE_DB:
            continue
        a = [dsp.to_db(sum(rs[lo:hi])) for lo, hi in zip(BAND_EDGES, BAND_EDGES[1:])]
        b = [dsp.to_db(sum(es[lo:hi])) for lo, hi in zip(BAND_EDGES, BAND_EDGES[1:])]
        ma, mb = sum(a) / len(a), sum(b) / len(b)
        num = sum((x - ma) * (y - mb) for x, y in zip(a, b))
        den = math.sqrt(sum((x - ma) ** 2 for x in a) * sum((y - mb) ** 2 for y in b))
        scores.append(max(0.0, num / den) if den else 0.0)
    return round(sum(scores) / len(scores), 4) if scores else 0.0


def _inside(t, spans):
    """Whether second `t` falls inside any `(first, last)` sample span."""
    return any(a <= t * dsp.ANALYSIS_RATE < b for a, b in spans)


def analyze(ref_samples, ref_rate, rec_samples, rec_rate, aligned=None):
    """The full report for one received recording against its reference clip."""
    ref, rec = dsp.decimate(ref_samples, ref_rate), dsp.decimate(rec_samples, rec_rate)
    starts, lags, *rest = aligned or align.track_locked(ref, rec)
    locked = rest[0] if rest else [True] * len(starts)
    expected = align.expected_signal(ref, len(rec), starts, lags)
    rec_db, exp_db = _frame_db(rec), _frame_db(expected)
    rec_spec, exp_spec = dsp.power_spectrogram(rec), dsp.power_spectrogram(expected)
    live = [r - e for r, e in zip(rec_db, exp_db) if e > ACTIVE_DB and r > -90]
    gain_db = statistics.median(live) if live else 0.0
    gain = 10 ** (gain_db / 20)
    events = (find_clipping(rec_samples, rec_rate)
              + find_dropouts(rec_db, exp_db, gain_db)
              + find_level_bursts(rec_db, exp_db, gain_db)
              + find_static(rec_db, rec_spec, exp_spec, exp_db, gain_db)
              + find_clicks(rec, expected, gain)
              + find_tones(rec_spec, exp_spec, gain))
    lost = align.lost_spans(starts, locked, len(rec))
    events = [e for e in events if e["class"] == "clipping" or not _inside(e["t"], lost)]
    events.sort(key=lambda e: e["t"])
    counts = {}
    for e in events:
        counts[e["class"]] = counts.get(e["class"], 0) + 1
    return {"seconds": round(len(rec) / dsp.ANALYSIS_RATE, 2),
            "similarity": similarity(rec_spec, exp_spec, exp_db),
            "gain_db": round(gain_db, 2), "counts": counts, "events": events,
            "timing": {**align.timing(starts, lags),
                       "lost_s": round(sum(b - a for a, b in lost) / dsp.ANALYSIS_RATE, 2)}}


def main(argv):
    ref, ref_rate = dsp.read_wav(argv[1])
    rec, rec_rate = dsp.read_wav(argv[2])
    report = analyze(ref, ref_rate, rec, rec_rate)
    if "--json" in argv:
        print(json.dumps(report, indent=2))
        return
    print(f"{report['seconds']}s  similarity {report['similarity']}  "
          f"gain {report['gain_db']} dB  counts {report['counts']}")
    print(f"timing {report['timing']}")
    for e in report["events"]:
        print(f"  {e['t']:7.2f}s {e['class']:9} {e['dur_ms']:5} ms  {e['detail']}")


if __name__ == "__main__":
    main(sys.argv)
