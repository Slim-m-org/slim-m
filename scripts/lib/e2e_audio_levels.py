# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The arithmetic the voice scenarios judge measured audio by.

Kept free of any browser so the thresholds' maths runs in a plain unit test:
a scenario that compares two levels is only as honest as the helper that
turns samples into those levels.
"""
import math

# Below this a signal is treated as silence rather than a very quiet voice.
SILENCE_DB = -80.0
# Floor for a zero sample, so a silent window still has a finite level.
_MIN_RMS = 1e-6


def rms_to_db(rms):
    """Full-scale relative level of an RMS amplitude (1.0 is 0 dB)."""
    return 20.0 * math.log10(max(rms, _MIN_RMS))


def percentile(values, pct):
    """Linear-interpolated percentile of a non-empty list, `pct` in 0..100."""
    if not values:
        raise ValueError("percentile of nothing")
    ordered = sorted(values)
    rank = (len(ordered) - 1) * pct / 100.0
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return ordered[int(rank)]
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def floor_and_speech(levels_db, floor_pct=10, speech_pct=95):
    """The quiet floor and the speech level of a stretch of per-window levels.

    The fixtures alternate speech with noise-only gaps, so a low percentile
    lands in a gap and a high one lands on a syllable, whichever way the
    looping file happens to be aligned with the measurement window.
    """
    return percentile(levels_db, floor_pct), percentile(levels_db, speech_pct)


def noise_reduction_db(floor_off_db, floor_on_db):
    """How many dB quieter the noise-only floor is with suppression on."""
    return floor_off_db - floor_on_db


def speech_loss_db(speech_off_db, speech_on_db):
    """How many dB quieter the speech is with suppression on (negative if louder)."""
    return speech_off_db - speech_on_db


def volume_to_db(volume):
    """The level change a playback multiplier should produce; silence for 0."""
    if volume <= 0:
        return SILENCE_DB
    return 20.0 * math.log10(volume)


def level_change_db(before_db, after_db):
    """`after - before`, clamped so two silences compare as no change."""
    return max(after_db, SILENCE_DB) - max(before_db, SILENCE_DB)


def applied_gain_db(samples, min_source_db=-50.0):
    """The gain the app applied, from windows where the source was audible.

    `samples` is `[(seconds, effective_db, source_db)]`, the heard level and
    the level of the same stream before the app's gain. Comparing the two in
    the same window cancels the sender's own level drift, which a comparison
    of two separate stretches of a call cannot. None when the source never
    cleared `min_source_db`, since then there is nothing to scale.
    """
    gains = [max(eff, SILENCE_DB) - src for _, eff, src in samples
             if src >= min_source_db]
    if not gains:
        return None
    return percentile(gains, 50)


def loudest_heard_db(samples, min_source_db=-50.0):
    """The loudest output while the source was audible: what leaked through a mute.

    None when the source never cleared `min_source_db`, since silence from a
    silent source proves nothing.
    """
    heard = [eff for _, eff, src in samples if src >= min_source_db]
    return max(heard) if heard else None


def longest_gap_seconds(samples, threshold_db):
    """The longest stretch with no window at or above `threshold_db`.

    `samples` is `[(seconds, level_db)]` in time order. The gap runs between
    consecutive loud windows; quiet at either end of the series is not counted
    because a measurement window starts mid-signal.
    """
    last_loud = None
    longest = 0.0
    for at, level in samples:
        if level < threshold_db:
            continue
        if last_loud is not None:
            longest = max(longest, at - last_loud)
        last_loud = at
    return longest


def luminance_stats(rgba, stride=4):
    """Mean and spread of the luminance of a flat RGBA byte sequence.

    A frame is live when its mean clears black; spread tells a flat fill from
    a picture with content in it.
    """
    values = []
    for i in range(0, len(rgba) - 3, stride):
        r, g, b = rgba[i], rgba[i + 1], rgba[i + 2]
        values.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
    if not values:
        return 0.0, 0.0
    mean = sum(values) / len(values)
    var = sum((v - mean) ** 2 for v in values) / len(values)
    return mean, math.sqrt(var)
