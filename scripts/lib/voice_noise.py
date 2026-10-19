# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How a call treated a noisy microphone: floor, noise events, speech level and word onsets.

The sender played speech with noise mixed in (make_noise_bed.py) and the
listener recorded what arrived. Three aligned views of the same moment are
compared: what was sent (the noisy mix), the speech alone, and what arrived.
All levels are dB over 10 ms frames at the analysis rate, so a change is
`arrived - sent` and negative means quieter.
"""
import math
import statistics

import voice_quality_align as align
import voice_quality_dsp as dsp

HOP = dsp.HOP
RATE = dsp.ANALYSIS_RATE
SPEECH_DB = -45.0
ONSET_WINDOW = 20
ONSET_DROP_DB = 10.0
CLIPPED_MS = 30
QUIET_FRAMES = 50
MARGIN_S = 0.3


def _db(signal):
    return [dsp.rms_db(signal[s:s + HOP]) for s in range(0, len(signal) - HOP + 1, HOP)]


def _power_mean(levels):
    """Mean of dB frames taken in power, so a loud burst counts as loud."""
    return 10 * math.log10(sum(10 ** (v / 10) for v in levels) / len(levels) + 1e-12)


class Aligned:
    """The sent speech, the sent mix and the recording on one timeline of 10 ms frames."""

    def __init__(self, clean, mix, rec):
        self.clean16, mix16, rec16 = (dsp.decimate(x, r) for x, r in (clean, mix, rec))
        self.starts, self.lags = align.track(self.clean16, rec16)
        self.size = len(rec16)
        self.clean = _db(self._signal(self.clean16))
        self.mix = _db(self._signal(mix16))
        self.rec = _db(rec16)
        self.frames = min(len(self.clean), len(self.mix), len(self.rec))

    def _signal(self, clip):
        return align.expected_signal(clip, self.size, self.starts, self.lags)

    def mask(self, spans, margin_s=0.0):
        """Frames of the recording that fall inside any clip-time `(start, end)` span."""
        indicator = [0.0] * len(self.clean16)
        for a, b in spans:
            lo, hi = max(0, int((a - margin_s) * RATE)), int((b + margin_s) * RATE)
            indicator[lo:hi] = [1.0] * (min(hi, len(indicator)) - lo)
        mapped = self._signal(indicator)
        return [i for i in range(self.frames) if mapped[i * HOP + HOP // 2] > 0.5]


def _pair(sent, got, frames):
    if not frames:
        return {"sent_db": None, "arrived_db": None, "change_db": None}
    s, g = _power_mean([sent[i] for i in frames]), _power_mean([got[i] for i in frames])
    return {"sent_db": round(s, 2), "arrived_db": round(g, 2), "change_db": round(g - s, 2)}


def _excess(view, level, frames, gain):
    """Level above the speech-only level over the frames where the speaker talks."""
    talk = [i for i in frames if view.clean[i] > SPEECH_DB]
    if not talk:
        return None
    return round(_power_mean([level[i] - gain for i in talk])
                 - _power_mean([view.clean[i] for i in talk]), 2)


def _onsets(view, speech):
    """Frames where speech starts after half a second of quiet."""
    inside = set(speech)
    return [i for i in range(QUIET_FRAMES, view.frames)
            if i in inside and view.clean[i] > SPEECH_DB
            and all(v <= SPEECH_DB for v in view.clean[i - QUIET_FRAMES:i])]


def _onset_loss(view, gain, speech):
    lost = []
    for i in _onsets(view, speech):
        window = range(i, min(view.frames, i + ONSET_WINDOW))
        lost.append(10 * sum(1 for j in window if view.clean[j] > SPEECH_DB
                             and view.rec[j] < view.clean[j] + gain - ONSET_DROP_DB))
    return {"count": len(lost),
            "mean_lost_ms": round(statistics.mean(lost), 1) if lost else 0.0,
            "worst_lost_ms": max(lost, default=0),
            "clipped": sum(1 for v in lost if v >= CLIPPED_MS)}


def analyze(clean, mix, rec, speech_spans, events):
    """`clean`, `mix`, `rec` are `(samples, rate)`; spans and events are seconds in the clip."""
    view = Aligned(clean, mix, rec)
    speech = view.mask(speech_spans)
    busy = set(view.mask([(e["start"], e["end"]) for e in events] + list(speech_spans),
                         MARGIN_S))
    live = [i for i in speech if view.clean[i] > SPEECH_DB]
    gain = statistics.median(view.rec[i] - view.clean[i] for i in live) if live else 0.0
    out = {"speech_level_change_db": round(gain, 2),
           "hum_floor": _pair(view.mix, view.rec,
                              [i for i in range(view.frames) if i not in busy])}
    for event in events:
        frames = view.mask([(event["start"], event["end"])])
        pair = _pair(view.mix, view.rec, frames)
        if event["kind"].endswith("speech"):
            pair["excess_over_speech_db"] = _excess(view, view.rec, frames, gain)
            pair["sent_excess_over_speech_db"] = _excess(view, view.mix, frames, 0.0)
        out[event["kind"]] = pair
    out["onsets"] = _onset_loss(view, gain, speech)
    return out
