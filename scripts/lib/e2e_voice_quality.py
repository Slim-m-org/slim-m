# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Two people in a call play known clips to each other; what arrives is scored.

Alice and bob each capture a different reference clip (make_quality_clip.py).
Each side taps the decoded remote track to PCM and samples the receive-side
concealment counters, once per network profile (e2e_netem.py). Analysis is
voice_quality.py's. Opt in with E2E_ONLY="voice quality"; the profiles come
from E2E_VQ_PROFILES (comma list, default all) and the capture length from
E2E_VQ_SECONDS. E2E_VQ_VARIANT names a row in VARIANTS, E2E_VQ_OUT the output.
"""
import base64
import json
import os
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor

import e2e_audio
import e2e_browsers
import e2e_labels as L
import e2e_netem
import e2e_voice_quality_js as js
import make_quality_clip
import make_speech_clip
import voice_corpus
import voice_quality
import voice_quality_dsp as dsp
from e2e_voice import _tap_label

SECONDS = int(os.environ.get("E2E_VQ_SECONDS", "45"))
SETTLE = 4
REEL_MARGIN = 8
CHUNK = 1_500_000
# Publish-side Opus parameters merged into the SDP (e2e_voice_quality_js.SDP_TWEAK).
VARIANTS = {
    "baseline": {},
    "no-fec": {"useinbandfec": "0"},
    "dtx-off": {"usedtx": "0"},
    "dtx-on": {"usedtx": "1"},
    "fec-dtx": {"useinbandfec": "1", "usedtx": "1"},
    "ptime40": {"_sender": {"ptime": 40}},
    "bitrate96": {"_sender": {"maxBitrate": 96000}},
    "bitrate64": {"_sender": {"maxBitrate": 64000}},
    "bitrate80": {"_sender": {"maxBitrate": 80000}},
    "dtx-off-br64": {"usedtx": "0", "_sender": {"maxBitrate": 64000}},
    "bitrate32-sender": {"_sender": {"maxBitrate": 32000}},
}


def clear_previous_run(directory):
    """A run scores only what it records: an earlier run's profiles and reel spans go first."""
    for name in os.listdir(directory):
        path = os.path.join(directory, name)
        if os.path.isdir(path):
            shutil.rmtree(path)
        elif name.endswith(".spans.json"):
            os.remove(path)


def write_clip(path, who):
    """The reference clip: the real-speech reel when E2E_VQ_CORPUS holds one, else piper speech, else the synthetic one."""
    folder = voice_corpus.corpus_dir()
    if folder:
        return voice_corpus.write_reel(path, who, folder)
    kind = os.environ.get("E2E_VQ_CLIPS", "speech")
    if kind == "speech":
        make_speech_clip.write(path, who, "speech")
    else:
        make_quality_clip.write(path, who)


def score_mos(directory, script="voice_quality_mos.py"):
    """DNSMOS per recording, run in the venv that has onnxruntime; skipped without it."""
    python = os.environ.get("E2E_VQ_MOS_PYTHON") or os.path.expanduser(
        "~/.slimm-scratch/mos-venv/bin/python")
    if not os.path.exists(python):
        print("  MOS skipped: no venv at", python)
        return
    here = os.path.dirname(os.path.abspath(__file__))
    subprocess.run([python, os.path.join(here, script), directory], check=True)


def capture_seconds(directory):
    """A reel needs one full pass to be scored per clip; a plain clip uses E2E_VQ_SECONDS."""
    ends = []
    for who in "AB":
        path = os.path.join(directory, f"clip-{who}.spans.json")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                ends.append(json.load(fh)[-1]["end"])
    if "E2E_VQ_SECONDS" in os.environ or not ends:
        return SECONDS
    return int(max(ends)) + REEL_MARGIN


def variant_name():
    """The variant's settings key; a numeric suffix names a repeat run of it."""
    name = os.environ.get("E2E_VQ_VARIANT", "baseline")
    if name in VARIANTS:
        return name
    # The longest key the name starts with, so bitrate642 is a repeat of bitrate64.
    keys = [k for k in VARIANTS if name.startswith(k) and name[len(k):].isdigit()]
    return max(keys, key=len) if keys else name


def out_dir():
    root = os.environ.get("E2E_VQ_OUT") or os.path.join(
        e2e_browsers.work_dir(), "voice-quality")
    path = os.path.join(root, os.environ.get("E2E_VQ_VARIANT", "baseline"))
    os.makedirs(path, exist_ok=True)
    return path


def _init_script(variant):
    tweak = json.dumps({k: v for k, v in VARIANTS[variant_name()].items()
                        if not k.startswith("_")})
    raw = "" if os.environ.get("E2E_VQ_PROCESSING") else js.RAW_CAPTURE_ALL
    return f"window.__vqSdp = {tweak};" + js.SDP_TWEAK + raw + js.COLLECT


def _ev_json(client, expr):
    return json.loads(client.ev(f"JSON.stringify({expr})") or "null")


def _record(client, seconds):
    """Taps the remote track for `seconds`; returns (pcm bytes, rate, stats rows)."""
    client.ev("window.__vq.reset(); window.__vq.ready = false; window.__vq.start();")
    deadline = time.time() + 15
    while not client.ev("window.__vq.ready"):
        err = client.ev("window.__vq.error")
        assert not err, f"{client.name}: could not tap the remote track: {err}"
        assert time.time() < deadline, f"{client.name}: the tap never came up"
        time.sleep(0.2)
    began = client.ev("window.__vq.mark()")
    time.sleep(seconds)
    total = client.ev("window.__vq.stop()")
    rate = client.ev("window.__vq.rate")
    parts, at = [], 0
    while at < total:
        count = min(CHUNK, total - at)
        parts.append(base64.b64decode(client.ev(f"window.__vq.slice({at}, {count})")))
        at += count
    stats = [r for r in _ev_json(client, "window.__vq.stats") if r["t"] >= began]
    return b"".join(parts), rate, stats


def _save(path, pcm, rate):
    import wave
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(pcm)


def stats_summary(rows):
    """Counter deltas over the window, per the receive-side stats names."""
    if len(rows) < 2:
        return {}
    first, last = rows[0], rows[-1]

    def delta(key):
        return round(last.get(key, 0) - first.get(key, 0), 4)

    emitted = delta("jitterBufferEmittedCount")
    return {
        "concealedSamples": delta("concealedSamples"),
        "concealmentEvents": delta("concealmentEvents"),
        "silentConcealedSamples": delta("silentConcealedSamples"),
        "insertedForDeceleration": delta("insertedSamplesForDeceleration"),
        "removedForAcceleration": delta("removedSamplesForAcceleration"),
        "packetsLost": delta("packetsLost"),
        "packetsReceived": delta("packetsReceived"),
        "fecPacketsReceived": delta("fecPacketsReceived"),
        "jitterMs": round(1000 * max(r.get("jitter", 0) for r in rows), 2),
        "jitterBufferDelayMs": round(
            1000 * delta("jitterBufferDelay") / emitted, 2) if emitted else 0,
        "bitrateKbps": round(8 * delta("bytesReceived") / max(
            (last["t"] - first["t"]) / 1000, 1) / 1000, 1),
        "peakAudioLevel": round(max(r.get("audioLevel", 0) for r in rows), 3),
    }


def analyse_saved(directory):
    """Scores every `<profile>/<who>-rx.wav` against the clip its sender played."""
    results = {}
    refs = {who: dsp.read_wav(os.path.join(directory, f"clip-{who}.wav"))
            for who in "AB"}
    for profile in sorted(os.listdir(directory)):
        folder = os.path.join(directory, profile)
        if not os.path.isdir(folder):
            continue
        for who, sender in (("vqa", "B"), ("vqb", "A")):
            path = os.path.join(folder, f"{who}-rx.wav")
            if not os.path.exists(path):
                continue
            rec, rate = dsp.read_wav(path)
            ref, ref_rate = refs[sender]
            report = voice_quality.analyze(ref, ref_rate, rec, rate)
            with open(os.path.join(folder, f"{who}-stats.json")) as fh:
                report["stats"] = json.load(fh)
            results.setdefault(profile, {})[who] = report
    with open(os.path.join(directory, "results.json"), "w") as fh:
        json.dump(results, fh, indent=2)
    return results


def a_scored_call(server, secret, admin_api, sign_in, room_id):
    e2e_netem.ensure_image()
    variant = variant_name()
    wanted = [p for p in os.environ.get(
        "E2E_VQ_PROFILES", ",".join(e2e_netem.PROFILES)).split(",") if p]
    directory = out_dir()
    clear_previous_run(directory)
    for who in "AB":
        write_clip(os.path.join(directory, f"clip-{who}.wav"), who)
    for user in ("vqa", "vqb"):
        e2e_browsers.register(server, admin_api, user, secret)
    script = _init_script(variant)
    pair = None
    with e2e_browsers.browser("vqa", os.path.join(directory, "clip-A.wav")) as ca, \
            e2e_browsers.browser("vqb", os.path.join(directory, "clip-B.wav")) as cb:
        for client, user in ((ca, "vqa"), (cb, "vqb")):
            e2e_audio.install(client, extra=script)
            sign_in(client, server, user, secret)
        try:
            for client in (ca, cb):
                e2e_browsers.dismiss_welcome(client)
                client.click(L.VOICE_CHANNEL)
                client.wait_for(L.IN_CALL)
            for client in (ca, cb):
                e2e_audio.AudioProbe(client).wait_for_streams(1)
            sender = VARIANTS[variant_name()].get("_sender")
            for client in (ca, cb):
                if sender:
                    client.ev(f"window.__vq.setSender({json.dumps(sender)})")
            time.sleep(SETTLE)
            for profile in wanted:
                print(f"  profile {profile}: {e2e_netem.apply(profile)}")
                time.sleep(SETTLE)
                folder = os.path.join(directory, profile)
                os.makedirs(folder, exist_ok=True)
                seconds = capture_seconds(directory)
                reel = os.path.exists(os.path.join(directory, "clip-A.spans.json"))
                with ThreadPoolExecutor(max_workers=2 if reel else 1) as pool:
                    recorded = list(pool.map(lambda c: _record(c, seconds), (ca, cb)))
                for client, (pcm, rate, rows) in zip((ca, cb), recorded):
                    _save(os.path.join(folder, f"{client.name}-rx.wav"), pcm, rate)
                    summary = stats_summary(rows)
                    summary["rows"] = len(rows)
                    summary["pair"] = _ev_json(client, "window.__vq.pair")
                    summary["outbound"] = _ev_json(client, "window.__vq.out")
                    summary["senders"] = e2e_audio.AudioProbe(client).senders()
                    summary["codec"] = _ev_json(client, "window.__vq.codecs")
                    pair = pair or summary["pair"]
                    with open(os.path.join(folder, f"{client.name}-stats.json"), "w") as fh:
                        json.dump(summary, fh, indent=2)
                    with open(os.path.join(folder, f"{client.name}-stats-raw.json"), "w") as fh:
                        json.dump(rows, fh)
        finally:
            e2e_netem.clear()
            for client in (ca, cb):
                if client.find(L.LEAVE_CALL):
                    _tap_label(client, L.LEAVE_CALL, settle=3)
    print(f"  selected ICE pair: {pair}")
    if os.path.exists(os.path.join(directory, "clip-A.spans.json")):
        score_mos(directory, "voice_corpus_score.py")
        return
    results = analyse_saved(directory)
    score_mos(directory)
    with open(os.path.join(directory, "results.json")) as fh:
        results = json.load(fh)
    for profile, sides in results.items():
        for who, report in sides.items():
            print(f"  {profile:18} {who} sim {report['similarity']:.3f} "
                  f"{report['counts']} conceal "
                  f"{report['stats'].get('concealedSamples')} mos {report.get('mos')}")
    clean = results.get("clean")
    if clean:
        for who, report in clean.items():
            assert report["similarity"] > 0.6, \
                f"{who}: the clean call scored {report['similarity']}"


def run_if_selected(server, secret, admin_api, sign_in, room_id):
    """Long and network-impairing, so only a run that names it takes part."""
    if "voice quality" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='voice quality' to run it")
        return
    a_scored_call(server, secret, admin_api, sign_in, room_id)
