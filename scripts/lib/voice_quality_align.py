# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Lines a received recording up with the looping reference clip it came from.

Chrome loops the fake capture file, so the recording starts at an arbitrary
point in the clip and has an unknown delay. A coarse pass finds that point on
the loudness envelope; a tracking pass then follows the delay every couple of
seconds on the waveform, which is what exposes drift and jitter-buffer steps.
"""
import math
from operator import mul

import voice_quality_dsp as dsp

SEGMENT = 2 * dsp.ANALYSIS_RATE
# Search this far either side of the previous delay: wide enough for a
# concealment insertion, narrower than most pitch periods' ambiguity.
TRACK_RADIUS_MS = 25
COARSE_DECIMATION = 4
# Segments quieter than this carry the previous delay forward.
MIN_ALIGN_DB = -50.0


def _envelope(signal):
    """Log loudness per 10 ms hop, shifted so silence is zero."""
    out = []
    for start in range(0, len(signal) - dsp.HOP + 1, dsp.HOP):
        out.append(max(dsp.rms_db(signal[start:start + dsp.HOP]), -60.0) + 60.0)
    return out


def _tile(ref, length):
    """`ref` repeated until it covers `length` samples plus one more loop."""
    copies = (length // len(ref)) + 2
    return ref * copies


def coarse_lag(ref, rec):
    """Samples into the looping ref that `rec[0]` sits at, to 10 ms."""
    env_ref = _envelope(ref)
    env_rec = _envelope(rec)
    mean_rec = sum(env_rec) / len(env_rec)
    env_rec = [v - mean_rec for v in env_rec]
    tiled = env_ref * ((len(env_rec) // len(env_ref)) + 2)
    scores = [sum(map(mul, tiled[lag:lag + len(env_rec)], env_rec))
              for lag in range(len(env_ref))]
    return scores.index(max(scores)) * dsp.HOP


def _box(values, step):
    if step == 1:
        return values
    return [sum(values[i:i + step]) / step
            for i in range(0, len(values) - step + 1, step)]


def _best_near(rec_part, tiled, center, radius, step):
    """The lag within `radius` of `center`, on a `step` grid, where the ref matches best."""
    low = max(0, center - radius)
    small = _box(rec_part, step)
    span = _box(tiled[low:low + 2 * radius + len(rec_part) + step], step)
    best, best_score = low, -math.inf
    for j in range((center + radius - low) // step + 1):
        window = span[j:j + len(small)]
        if len(window) < len(small):
            break
        energy = math.sqrt(sum(map(mul, window, window)) or 1e-12)
        score = sum(map(mul, small, window)) / energy
        if score > best_score:
            best, best_score = low + j * step, score
    return best


def track(ref, rec):
    """`(starts, lags)`: the delay into the looping ref for each 2 s segment of rec."""
    tiled = _tile(ref, len(rec) + abs(len(ref)))
    lag = coarse_lag(ref, rec)
    radius = TRACK_RADIUS_MS * dsp.ANALYSIS_RATE // 1000
    starts, lags = [], []
    first = True
    for start in range(0, len(rec), SEGMENT):
        part = rec[start:start + SEGMENT]
        if len(part) < dsp.FRAME:
            break
        starts.append(start)
        if dsp.rms_db(part) < MIN_ALIGN_DB:
            lags.append(lag)
            continue
        wide = radius * 3 if first else radius
        first = False
        guess = _best_near(part, tiled, lag + start, wide, COARSE_DECIMATION) - start
        fine = _best_near(part, tiled, guess + start, COARSE_DECIMATION, 1) - start
        lag = fine
        lags.append(lag)
    return starts, lags


def expected_signal(ref, rec_length, starts, lags):
    """What the receiver should have heard, sample for sample, under the tracked delay."""
    tiled = _tile(ref, rec_length + len(ref))
    out = []
    for i, (start, lag) in enumerate(zip(starts, lags)):
        end = starts[i + 1] if i + 1 < len(starts) else rec_length
        out += tiled[start + lag:end + lag]
    out += [0.0] * (rec_length - len(out))
    return out


def timing(starts, lags):
    """Delay drift and steps in milliseconds, from the tracked lags ."""
    if not lags:
        return {"drift_ms": 0.0, "drift_ms_per_min": 0.0, "max_step_ms": 0.0,
                "steps": []}
    ms = [(v - lags[0]) * 1000.0 / dsp.ANALYSIS_RATE for v in lags]
    seconds = [s / dsp.ANALYSIS_RATE for s in starts]
    steps = [{"t": round(seconds[i + 1], 2), "step_ms": round(ms[i + 1] - ms[i], 2)}
             for i in range(len(ms) - 1) if abs(ms[i + 1] - ms[i]) >= 5.0]
    span = (seconds[-1] - seconds[0]) or 1.0
    return {"drift_ms": round(ms[-1] - ms[0], 2),
            "drift_ms_per_min": round((ms[-1] - ms[0]) / span * 60.0, 2),
            "max_step_ms": round(max((abs(ms[i + 1] - ms[i])
                                      for i in range(len(ms) - 1)), default=0.0), 2),
            "steps": steps}
