# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Mouth and desk sounds through the real Linux client: what each suppression arm does to them.

The owner hears chewing, swallowing and room noise reach a call with Strong on, sometimes louder than the voice around them.
This plays speech with lip smacks, chewing, a swallow and a breath (synthetic, or recorded clips from E2E_TRANSIENT_CLIPS) through the desktop client under Standard, Strong, Strong with auto gain off, and Strongest, and scores every event as sent against as heard.
Opt in with E2E_ONLY="voice transients"; the desktop scenario's E2E_DESKTOP_* variables apply.
"""
import glob
import os

import e2e_voice_desktop as desktop
import voice_quality_dsp as dsp

KINDS = ("smack", "chew", "swallow", "breath")
# A gap event may never come out louder than it went in; a listener hears that as the suppressor pumping.
AMPLIFY_MAX_DB = 1.0
# Speech itself must survive every arm within this much of its sent level.
SPEECH_DRIFT_MAX_DB = 3.0
ARMS = {
    "standard-gate-on": desktop.arm_prefs("standard", desktop.GATE_ON),
    "strong-gate-on": desktop.arm_prefs("strong", desktop.GATE_ON),
    "strong-agc-off": desktop.arm_prefs("strong", desktop.GATE_ON, **{"slimm.voice.auto_gain": False}),
    "strongest-gate-on": desktop.arm_prefs("strongest", desktop.GATE_ON),
}


def recorded_clips(folder):
    """One recorded clip per kind from `folder` (files named `<kind>-*.wav`), or None when it has none."""
    found = {}
    for kind in KINDS:
        paths = sorted(glob.glob(os.path.join(folder, f"{kind}-*.wav")))
        if paths:
            samples, rate = dsp.read_wav(paths[0])
            assert rate == 48000, f"{paths[0]} is {rate} Hz, the harness mixes at 48 kHz"
            found[kind] = samples
    return found or None


def transients_from_env():
    folder = os.environ.get("E2E_TRANSIENT_CLIPS")
    return recorded_clips(folder) if folder else True


def problems(results):
    """Why a run fails: an event came out louder than it went in, or speech moved too far."""
    out = []
    for voice, arms in results.items():
        for arm, profiles in arms.items():
            for profile, row in profiles.items():
                if profile == "gate_log":
                    continue
                noise = row["noise"]
                drift = noise["speech_level_change_db"]
                if abs(drift) > SPEECH_DRIFT_MAX_DB:
                    out.append(f"{voice} {arm} {profile}: speech moved {drift:+.1f} dB")
                for kind, event in noise.items():
                    if not isinstance(event, dict) or not kind.endswith("_gap"):
                        continue
                    peak = event.get("peak_change_db")
                    if peak is not None and peak > AMPLIFY_MAX_DB:
                        out.append(f"{voice} {arm} {profile}: {kind} came out {peak:+.1f} dB louder in its loudest frame")
    return out


def table(results):
    """One line per arm and gap event: energy change, worst frame, and how it sits against the voice."""
    lines = []
    for voice, arms in results.items():
        for arm, profiles in arms.items():
            for profile, row in profiles.items():
                if profile == "gate_log":
                    continue
                noise = row["noise"]
                for kind in sorted(k for k in noise if k.endswith("_gap")):
                    e = noise[kind]
                    lines.append(f"  {voice:8} {arm:18} {profile:8} {kind:13} change {e['change_db']:+6.1f} dB"
                                 f"  worst {e['peak_change_db']!s:>6}  over speech {e.get('over_speech_db')!s:>6}")
                lines.append(f"  {voice:8} {arm:18} {profile:8} speech {noise['speech_level_change_db']:+.1f} dB"
                             f"  onsets clipped {noise['onsets']['clipped']}/{noise['onsets']['count']}")
    return "\n".join(lines)


def mouth_sounds_through_the_desktop(server, secret, admin_api, sign_in):
    run = desktop.Run.from_env(arms=dict(ARMS), profiles=("clean",),
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
