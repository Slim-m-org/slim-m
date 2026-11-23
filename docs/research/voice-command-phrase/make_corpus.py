# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Synthesises the wake-phrase corpus: piper speech, padded, with noise and music at set SNRs."""
import json, subprocess, sys, wave
from pathlib import Path
import numpy as np
from score import under_cwd

OUT = under_cwd(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)
PIPER = str(Path.home() / ".slimm-scratch/piper-venv/bin/piper")
VOICES = {v: str(Path.home() / f".slimm-scratch/piper-voices/en_US-{v}-medium.onnx") for v in ("lessac", "ryan")}
SPEEDS = {"fast": 0.85, "normal": 1.0, "slow": 1.2}
RATE = 16000

POS = [
    ("alone_mark", ["hey space, mark that"], "mark"),
    ("alone_mark_this", ["hey space, mark this"], "mark"),
    ("alone_bookmark", ["hey space, bookmark that"], "mark"),
    ("alone_clip", ["hey space, clip that"], "mark"),
    ("note_plumber", ["hey space, note call the plumber tomorrow morning"], "note"),
    ("note_budget", ["hey space, note the budget is due on Friday"], "note"),
    ("start_mark", ["hey space, mark that, the build numbers look wrong"], "mark"),
    ("end_mark", ["the build numbers look wrong, hey space, mark that"], "mark"),
    ("filler_mark", ["okay so hey space, please mark that"], "mark"),
    ("end_note", ["that was a good point, hey space, note ask Ada about the release"], "note"),
    ("split_mark", ["hey space", "mark that"], "mark"),
]
NEG = [
    "hey, space it out a bit more", "that clip was really funny", "mark my words, it will rain tomorrow",
    "note that the space is limited", "hey, can you make some space on the drive", "I marked the spreadsheet yesterday",
    "the spacebar on my keyboard is stuck", "hey Mark, did you see that", "there is no space left for notes here",
    "hey, take a note of that", "space, the final frontier", "we should mark that down as done",
    "hey, did anyone mark that ticket", "the notebook has a lot of space", "hey Spencer, mark that",
    "hey Stacey, mark that one for me", "can you clip that video for me", "please note the meeting moved",
    "she said hey and then left", "my space heater broke last night", "hey, it's fine, note it later",
    "the bookmark is on the second page", "they clipped the hedge this morning", "hey there, how is everyone",
    "we need more office space", "put a mark next to the third item",
    "I think the deploy went fine", "can everyone see my screen", "let's take a five minute break",
    "the second build failed on the lint step", "I will fix it after this call", "who is taking notes today",
    "did you get my message about the server", "the coffee machine is broken again", "we should ship it on Friday",
    "can you hear me now", "sorry, I was on mute", "let me share the document", "that sounds good to me",
    "what time is the release tomorrow", "I'll send the link in the chat", "the numbers look better this week",
    "has anyone tried the new phone build", "the game starts in ten minutes", "okay, I need to go soon",
]

def piper(text, voice, speed, path):
    subprocess.run([PIPER, "-m", VOICES[voice], "-f", str(path), "--length-scale", str(speed)],
                   input=text.encode(), check=True, capture_output=True)
    w = wave.open(str(path)); rate = w.getframerate()
    pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
    idx = np.arange(0, len(pcm), rate / RATE)
    return np.interp(idx, np.arange(len(pcm)), pcm)

rng = np.random.default_rng(7)

def room(n):
    white = rng.standard_normal(n)
    b = np.cumsum(white); b -= np.convolve(b, np.ones(400) / 400, mode="same")
    return b / (np.std(b) + 1e-9)

def music(n):
    t = np.arange(n) / RATE
    chords = [(220, 277, 330), (196, 247, 294), (175, 220, 262), (165, 208, 247)]
    out = np.zeros(n)
    for i, chord in enumerate(chords * (n // (RATE * 2) // 4 + 1)):
        s, e = i * RATE * 2, min(n, (i + 1) * RATE * 2)
        if s >= n: break
        for f in chord:
            out[s:e] += np.sin(2 * np.pi * f * t[s:e]) * np.exp(-((t[s:e] - t[s]) % 0.5) * 3)
    return out / (np.std(out) + 1e-9)

def mix(speech, kind, snr):
    if kind == "clean": return speech
    noise = room(len(speech)) if kind == "room" else music(len(speech))
    voiced = speech[np.abs(speech) > 200]
    p = np.sqrt(np.mean(voiced ** 2)) if len(voiced) else 1000.0
    return speech + noise * p / (10 ** (snr / 20))

CONDS = [("clean", None), ("room", 20), ("room", 10), ("music", 10)]

def write(path, x):
    x = np.clip(x, -32768, 32767).astype(np.int16)
    w = wave.open(str(path), "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(x.tobytes()); w.close()

manifest = []
tmp = OUT / "_t.wav"
def build(parts, voice, speed):
    gap = np.zeros(int(RATE * 1.2))
    speech = [np.zeros(RATE // 2)]
    for i, text in enumerate(parts):
        if i: speech.append(gap)
        speech.append(piper(text, voice, speed, tmp))
    speech.append(np.zeros(RATE)); return np.concatenate(speech)

for voice in VOICES:
    for sname, speed in SPEEDS.items():
        for name, parts, kind in POS:
            clean = build(parts, voice, speed)
            for cond, snr in CONDS:
                f = f"pos_{name}_{voice}_{sname}_{cond}{snr or ''}.wav"
                write(OUT / f, mix(clean, cond, snr)); manifest.append({"file": f, "expect": kind, "said": " / ".join(parts), "voice": voice, "speed": sname, "cond": f"{cond}{snr or ''}", "seconds": len(clean) / RATE})
        for i, text in enumerate(NEG):
            clean = build([text], voice, speed)
            for cond, snr in CONDS:
                f = f"neg_{i:02d}_{voice}_{sname}_{cond}{snr or ''}.wav"
                write(OUT / f, mix(clean, cond, snr)); manifest.append({"file": f, "expect": "none", "said": text, "voice": voice, "speed": sname, "cond": f"{cond}{snr or ''}", "seconds": len(clean) / RATE})
for kind in ("room", "music"):
    n = RATE * 120
    x = (room(n) if kind == "room" else music(n)) * 300
    f = f"bg_{kind}.wav"; write(OUT / f, x); manifest.append({"file": f, "expect": "none", "said": "", "voice": "", "speed": "", "cond": kind, "seconds": 120})
write(OUT / "bg_silence.wav", np.zeros(RATE * 60)); manifest.append({"file": "bg_silence.wav", "expect": "none", "said": "", "voice": "", "speed": "", "cond": "silence", "seconds": 60})
tmp.unlink(missing_ok=True)
with (OUT / "manifest.json").open("w") as dest:
    json.dump(manifest, dest, indent=1)
print(len(manifest), "clips", round(sum(m["seconds"] for m in manifest) / 3600, 2), "hours")
