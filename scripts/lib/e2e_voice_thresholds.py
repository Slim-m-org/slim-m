# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The pass/fail rules of the voice scenarios that used to only print what they measured.

Every number is a ceiling or floor set with headroom around a baseline measured on this harness; the measured value sits in the comment beside it.
The functions here are pure so the rules are unit tested without a call, a browser or a desktop build.
"""
import re

# What only a call tile says after a name; a member row reads "Alice, online".
TILE_WORDS = re.compile(r", (microphone on|muted|connecting)\b")


def tile_line(texts, who):
    """The call tile line naming `who` among accessibility node texts, or None."""
    for text in texts:
        for line in text.split("\n"):
            if line.startswith(f"{who}, ") and TILE_WORDS.search(line):
                return line
    return None


# Measured on the real Linux client (docs/research/voice-quality-harness-v2.md): Standard -17 to -20 dB, Strong -66 to -68 dB, speech -0.1 to +1.3 dB.
HUM_REDUCTION_MIN_DB = 8.0
SPEECH_LOSS_MAX_DB = 3.0
STRONG_EXTRA_REDUCTION_MIN_DB = 12.0


def noise_problems(arm, profile, noise):
    """Why one arm's recording on one network profile is not quieter in the gaps or has lost speech, from voice_noise.analyze."""
    found = []
    change = noise["hum_floor"].get("change_db")
    if change is None or change > -HUM_REDUCTION_MIN_DB:
        found.append(f"{arm} {profile}: the noise floor changed {change} dB, "
                     f"short of -{HUM_REDUCTION_MIN_DB}")
    level = noise["speech_level_change_db"]
    if level < -SPEECH_LOSS_MAX_DB:
        found.append(f"{arm} {profile}: the speech arrived {-level:.1f} dB quieter, "
                     f"over {SPEECH_LOSS_MAX_DB}")
    return found


def strong_problems(profile, standard, strong):
    """Strong, on the same network profile and gate setting, has to take more off the floor than Standard."""
    std, stg = (r["hum_floor"].get("change_db") for r in (standard, strong))
    if std is None or stg is None or std - stg < STRONG_EXTRA_REDUCTION_MIN_DB:
        return [f"{profile}: Strong's floor changed {stg} dB against Standard's {std}, "
                f"under {STRONG_EXTRA_REDUCTION_MIN_DB} dB more"]
    return []


def _has_noise(row):
    return isinstance(row, dict) and "noise" in row


def arm_problems(rows):
    """Every threshold over a finished desktop run, `rows` being {arm: {profile: {"noise": analyze output}}}."""
    found = []
    for arm, profiles in rows.items():
        for profile, row in profiles.items():
            if _has_noise(row):
                found += noise_problems(arm, profile, row["noise"])
    standard, strong = rows.get("standard-gate-off", {}), rows.get("strong-gate-off", {})
    for profile in standard:
        if profile in strong and _has_noise(standard[profile]) and _has_noise(strong[profile]):
            found += strong_problems(profile, standard[profile]["noise"], strong[profile]["noise"])
    return found


# Encode readback: what a tier asks for, fitted into the source the way the client does (fitScreenShare).
MIN_SHARE_FPS = 12.0
SIZE_TOLERANCE = 0.02
TIER = re.compile(r"(\d+)p(\d+)")
CAMERA_TOP_HEIGHT = {"datasaver": 360, "balanced": 720, "high": 1080}


def _even(value):
    return int(round(value / 2.0)) * 2


def expected_top(case):
    """The (width, height) a case's top layer should deliver, or None when the case does not pin one."""
    if case["source"] == "camera":
        height = CAMERA_TOP_HEIGHT.get(case["label"].partition(":")[2].lower())
        return None if height is None else (_even(height * 16 / 9), height)
    tier = TIER.search(case["flags"][0])
    box_h = int(tier.group(1))
    box_w = _even(box_h * 16 / 9)
    width, height = case["size"]
    scale = min(1.0, box_w / width, box_h / height)
    return _even(width * scale), _even(height * scale)


def _top(layers):
    return max(layers, key=lambda l: int(l["height"]))


def encode_problems(case, result):
    """Why a case's sender stats do not match what was asked: top layer size, frame rate, a low layer at about half, a restart."""
    found = []
    layers = result["layers"]
    if not layers:
        return [f"{case['label']}: no sender stats printed"]
    top = _top(layers)
    want = expected_top(case)
    if want is not None:
        got = (int(top["width"]), int(top["height"]))
        if any(abs(g - w) > w * SIZE_TOLERANCE + 2 for g, w in zip(got, want)):
            found.append(f"{case['label']}: top layer is {got[0]}x{got[1]}, asked for {want[0]}x{want[1]}")
    if case["source"] == "screenShare" and float(top["fps"]) < MIN_SHARE_FPS:
        found.append(f"{case['label']}: top layer ran at {top['fps']} fps, under {MIN_SHARE_FPS}")
    if "restart" in case["label"] and not result["restarted"]:
        found.append(f"{case['label']}: the share never came back after the restart")
    return found


def growing_streams(first, after, frames=5):
    """The inbound videos whose decoded-frame count rose by more than `frames` between two samples."""
    return [k for k, n in after.items() if n - first.get(k, 0) > frames]


# Voice quality, piper speech on this box: similarity 0.972 to 0.996 and no lost seconds on every profile, burst and loss5-jitter30 included.
SIMILARITY_MIN = {"clean": 0.9, "loss2": 0.9, "loss5-jitter30": 0.9, "delay150-jitter50": 0.9, "burst": 0.9}
OTHER_PROFILE_SIMILARITY_MIN = 0.8
LOST_S_MAX = 1.0


def quality_problems(results):
    """Why a scored call missed its floors, `results` being {profile: {side: report}} from analyse_saved."""
    found = []
    for profile, sides in results.items():
        floor = SIMILARITY_MIN.get(profile, OTHER_PROFILE_SIMILARITY_MIN)
        for who, report in sides.items():
            if report["similarity"] < floor:
                found.append(f"{profile} {who}: similarity {report['similarity']:.3f}, under {floor}")
            lost = report["timing"]["lost_s"]
            if lost > LOST_S_MAX:
                found.append(f"{profile} {who}: {lost}s of the clip never arrived, over {LOST_S_MAX}")
    return found


def corpus_problems(scores, wanted):
    """Why a corpus scorer's output proves nothing: a recorded profile missing, or one with a direction unscored."""
    found = [f"{profile}: the corpus scorer wrote nothing" for profile in wanted if profile not in scores]
    found += [f"{profile}: only {sorted(sides)} were scored, not vqa and vqb"
              for profile, sides in scores.items() if sorted(sides) != ["vqa", "vqb"]]
    return found
