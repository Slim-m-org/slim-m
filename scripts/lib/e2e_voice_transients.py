# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Mouth and desk sounds through the real Linux client: what each suppression arm does to them.

The owner hears chewing, swallowing and room noise reach a call with Strong on, sometimes louder than the voice around them.
This plays speech with lip smacks, chewing, a swallow and a breath through the desktop client under Standard, Strong and Strong with auto gain off (Strongest on request), and scores every event as sent against as heard.
The sounds are the recorded CC0 clips fetch_mouth_noise.py builds when they exist (or E2E_TRANSIENT_CLIPS names a folder of `<kind>-*.wav`), else the synthetic set; E2E_TRANSIENT_CLIPS=synthetic forces the latter.
Opt in with E2E_ONLY="voice transients"; the desktop scenario's E2E_DESKTOP_* variables apply.
"""
import glob
import os

import e2e_voice_desktop as desktop
import fetch_mouth_noise
import voice_quality_dsp as dsp

KINDS = ("smack", "chew", "swallow", "breath")
# In an arm the native chain owns, a gap event may never come out louder than it went in; a listener hears that as pumping.
AMPLIFY_MAX_DB = 1.0
# The loudest 10 ms frame is a looser cap: a sharp onset reads 2 to 3 dB either way from frame alignment alone.
PEAK_MAX_DB = 4.0
# Standard is libwebrtc's own processing, reported for comparison and not judged: its auto gain lifts an isolated sound by several dB.
JUDGED_CHOICES = ("strong", "strongest")
# Strongest runs only via E2E_DESKTOP_ARMS: DeepFilterNet's known 3 dB speech cost (its own card) would fail the speech bound every time.
DEFAULT_ARMS = ("standard-gate-on", "strong-gate-on", "strong-agc-off")
# Speech itself must survive every arm within this much of its sent level.
SPEECH_DRIFT_MAX_DB = 3.0
# A recorded clip is cut to its loudest stretch of this length, so it fits a sentence gap with clean air around it.
CLIP_SECONDS = 1.5
# The clips are peak-normalised to -6 dBFS; a mouth noise at a desk sits this far under that.
CLIP_GAIN_DB = -12.0
ARMS = {
    "standard-gate-on": desktop.arm_prefs("standard", desktop.GATE_ON),
    "strong-gate-on": desktop.arm_prefs("strong", desktop.GATE_ON),
    "strong-agc-off": desktop.arm_prefs("strong", desktop.GATE_ON, **{"slimm.voice.auto_gain": False}),
    "strongest-gate-on": desktop.arm_prefs("strongest", desktop.GATE_ON),
}


def loudest_window(samples, seconds, rate=48000):
    """The `seconds` long stretch of `samples` with the most energy, stepped in 100 ms."""
    size, step = int(seconds * rate), rate // 10
    if len(samples) <= size:
        return list(samples)
    energy = [v * v for v in samples]
    best_at, best = 0, -1.0
    for at in range(0, len(samples) - size + 1, step):
        total = sum(energy[at:at + size])
        if total > best:
            best_at, best = at, total
    return samples[best_at:best_at + size]


def recorded_clips(folder):
    """One recorded clip per kind from `folder` (files named `<kind>-*.wav`), cut and levelled, or None when it has none."""
    found = {}
    gain = 10 ** (CLIP_GAIN_DB / 20)
    for kind in KINDS:
        paths = sorted(glob.glob(os.path.join(folder, f"{kind}-*.wav")))
        if paths:
            samples, rate = dsp.read_wav(paths[0])
            assert rate == 48000, f"{paths[0]} is {rate} Hz, the harness mixes at 48 kHz"
            found[kind] = [v * gain for v in loudest_window(samples, CLIP_SECONDS)]
    return found or None


def transients_from_env():
    """Recorded clips from E2E_TRANSIENT_CLIPS, else the fetched corpus when it exists, else the synthetic set."""
    folder = os.environ.get("E2E_TRANSIENT_CLIPS") or fetch_mouth_noise.DEFAULT_OUT
    if os.environ.get("E2E_TRANSIENT_CLIPS") == "synthetic":
        return True
    return recorded_clips(folder) or True


def judged(arm, arms=ARMS):
    """Whether `arm` runs the native chain, which is what this scenario holds to account."""
    return arms.get(arm, {}).get("slimm.voice.noise_suppression") in JUDGED_CHOICES


def _gap_problems(noise):
    """Each gap event that came out louder than it went in, by energy or by its loudest frame."""
    out = []
    for kind, event in noise.items():
        if not isinstance(event, dict) or not kind.endswith("_gap"):
            continue
        change, peak = event.get("change_db"), event.get("peak_change_db")
        if change is not None and change > AMPLIFY_MAX_DB:
            out.append(f"{kind} came out {change:+.1f} dB louder")
        elif peak is not None and peak > PEAK_MAX_DB:
            out.append(f"{kind} came out {peak:+.1f} dB louder in its loudest frame")
    return out


def _row_problems(noise, held_to_account):
    """One measured arm and profile: speech drift always, gap events only where the chain owns them."""
    drift = noise["speech_level_change_db"]
    out = [f"speech moved {drift:+.1f} dB"] if abs(drift) > SPEECH_DRIFT_MAX_DB else []
    if held_to_account:
        out += _gap_problems(noise)
    return out


def measured_rows(results):
    """Every (voice, arm, profile, row) in a run, skipping the gate logs stored beside the profiles."""
    for voice, per_arm in results.items():
        for arm, profiles in per_arm.items():
            for profile, row in profiles.items():
                if profile != "gate_log":
                    yield voice, arm, profile, row


def problems(results, arms=ARMS):
    """Why a run fails: speech moved too far in any arm, or a gap event came out louder in an arm the chain owns."""
    return [f"{voice} {arm} {profile}: {why}"
            for voice, arm, profile, row in measured_rows(results)
            for why in _row_problems(row["noise"], judged(arm, arms))]


def table(results):
    """One line per arm and gap event: energy change, worst frame, and how it sits against the voice."""
    lines = []
    for voice, arm, profile, row in measured_rows(results):
        noise = row["noise"]
        for kind in sorted(k for k in noise if k.endswith("_gap")):
            e = noise[kind]
            lines.append(f"  {voice:8} {arm:18} {profile:8} {kind:13} change {e['change_db']:+6.1f} dB"
                         f"  worst {e['peak_change_db']!s:>6}  over speech {e.get('over_speech_db')!s:>6}")
        lines.append(f"  {voice:8} {arm:18} {profile:8} speech {noise['speech_level_change_db']:+.1f} dB"
                     f"  onsets clipped {noise['onsets']['clipped']}/{noise['onsets']['count']}")
    return "\n".join(lines)


def mouth_sounds_through_the_desktop(server, secret, admin_api, sign_in):
    arms = dict(ARMS) if os.environ.get("E2E_DESKTOP_ARMS") else {name: ARMS[name] for name in DEFAULT_ARMS}
    run = desktop.Run.from_env(arms=arms, profiles=("clean",),
                               transients=transients_from_env(), label="transients")
    results = desktop.a_noisy_desktop(server, secret, admin_api, sign_in, run)
    print(table(results), flush=True)
    found = problems(results)
    assert not found, "; ".join(found)


def run_if_selected(server, secret, admin_api, sign_in):
    if "voice transients" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='voice transients' to run it")
        return
    mouth_sounds_through_the_desktop(server, secret, admin_api, sign_in)
