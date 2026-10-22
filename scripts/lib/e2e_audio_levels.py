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


def slider_to_gain(slider):
    """The playback gain for a slider position: the cube below 100%, linear above (audio_gain.dart)."""
    return slider ** 3 if slider <= 1.0 else slider


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


def longest_gap_seconds(samples, threshold_db, until=None):
    """The longest stretch with no window at or above `threshold_db`.

    `samples` is `[(seconds, level_db)]` in time order. The gap runs between
    consecutive loud windows; quiet before the first loud window is not
    counted because a measurement window starts mid-signal. With `until` (the
    time the reading ended) silence after the last loud window counts too, so
    a dropout longer than the read cannot pass unseen; a series that never
    gets loud is then one gap from its first window to `until`.
    """
    last_loud = None
    longest = 0.0
    for at, level in samples:
        if level < threshold_db:
            continue
        if last_loud is not None:
            longest = max(longest, at - last_loud)
        last_loud = at
    if until is not None:
        anchor = last_loud
        if anchor is None and samples:
            anchor = samples[0][0]
        if anchor is not None:
            longest = max(longest, until - anchor)
    return longest


def refuse_unplayed(rows, who, stream_id, max_fraction=0.25):
    """Raise when too many raw probe windows came from an element not playing.

    `rows` is the probe's `[ms, rms, pre_rms, flag]`; a flag means the element
    was paused or stalled, or the app's AudioContext was suspended under a tap.
    Such windows read as silence, which would pass a "muted" assertion for the
    wrong reason.
    """
    flagged = [r[3] for r in rows if len(r) > 3 and r[3]]
    if rows and len(flagged) > max_fraction * len(rows):
        raise AssertionError(
            f"{who}: stream {stream_id} was not really playing in "
            f"{len(flagged)} of {len(rows)} windows ({sorted(set(flagged))}); "
            f"a measurement of it proves nothing")
