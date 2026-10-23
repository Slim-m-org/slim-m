"""dj solo-call music. Run: python3 generate.py  (writes wav/lofi.wav and wav/electronic.wav)."""
import numpy as np

import dsp
from dsp import Mix, hz, SR

# D major pentatonic is D E F# A B; chords stay inside D major so a chime over them agrees.
CH = {
    "Dmaj7": ([54, 57, 61, 64], 50), "Bm9": ([54, 57, 62, 64], 47),
    "Gmaj9": ([59, 62, 64, 66], 43), "A9": ([55, 59, 61, 64], 45),
    "Em9": ([55, 59, 62, 66], 40), "F#m7": ([57, 61, 64, 66], 42),
}
PROG_A = ["Dmaj7", "Bm9", "Gmaj9", "A9", "Em9", "F#m7", "Gmaj9", "A9"]
PENT = [74, 76, 78, 81, 83, 86, 88, 90]  # D5 E5 F#5 A5 B5 D6 E6 F#6


def _lofi_keys(bar, rng, chords, t_of, keys):
    hits = [(0, 1.0), (7, 0.7)] + ([(10, 0.55)] if bar % 2 else [(14, 0.45)])
    for s, v in hits:
        base = t_of(bar, s)
        for i, (m, l, r) in enumerate(chords):
            j = i * 0.011 + rng.uniform(-0.006, 0.006)
            g = v * (0.85 + 0.3 * rng.random())
            keys.add(l * 0.9, base + j, -0.5, 0.2 * g)
            keys.add(r * 0.9, base + j, 0.5, 0.2 * g)


def _lofi_bass(bar, root, rng, t_of, beat, bas):
    # bass: root, anticipation, root an octave up
    bp = [(0, 1.0, 1.1), (7, 0.7, 0.55), (11, 0.6, 0.5)] if bar % 4 != 3 else [(0, 1.0, 1.1), (6, 0.7, 0.5), (12, 0.6, 0.6)]
    for s, v, d in bp:
        bas.add(dsp.bass(root + (12 if s == 11 and bar % 2 else 0), d * beat, v), t_of(bar, s) + rng.uniform(-0.005, 0.005), 0, 0.5)


def _lofi_drums(bar, rng, t_of, drums):
    ks = [[0, 10], [0, 7, 10], [0, 10], [0, 6, 10, 15]][bar % 4]
    for s in ks:
        drums.add(dsp.kick(0.9 if s == 0 else 0.6), t_of(bar, s), 0, 0.5)
    for s, v in ((4, 1.0), (12, 1.0), (15 if bar % 4 == 3 else -1, 0.3)):
        if s >= 0:
            drums.add(dsp.snare(rng, v * (0.85 + 0.3 * rng.random())), t_of(bar, s) + 0.004, 0.05, 0.25)
    for s in range(0, 16, 2):
        v = (0.9 if s % 4 == 0 else 0.55) * (0.8 + 0.4 * rng.random())
        drums.add(dsp.noise(rng, 0.05, 5500, 9500, 0.012), t_of(bar, s), 0.3, 0.08 * v)


def _lofi_melody(bar, rng, t_of, mel):
    # sparse D pentatonic, only in the second half of each 16-bar phrase
    if bar % 16 < 8 or bar % 2:
        return
    idx = int(rng.integers(0, 5))
    for off in (2, 5, 8, 12):
        if rng.random() < 0.7:
            idx = int(np.clip(idx + rng.integers(-2, 3), 0, 6))
            mel.add(dsp.bar(PENT[idx] - 12 * int(idx > 4), 0.5, 0.8), t_of(bar, off), -0.3, 0.12)


def lofi():
    rng = np.random.default_rng(1107)
    bpm = 76.0
    beat = 60.0 / bpm
    nb = 32
    bar_s = 4 * beat
    mix_len = nb * bar_s
    keys, bas, drums, mel, _ = (Mix(mix_len) for _ in range(5))
    sw = 0.16  # swing on the off 16ths
    step = beat / 4

    def t_of(bar, s):
        return bar * bar_s + (s + (sw if s % 2 else 0.0)) * step

    # unique chord renders, placed with human timing
    cache = {}
    for name, (notes, _) in CH.items():
        cache[name] = [(m, dsp.ep(m, 1.6, 0.8, d), dsp.ep(m, 1.6, 0.8, -d)) for m, d in zip(notes, (-4, 3, -2, 5))]
    for bar in range(nb):
        name = PROG_A[bar % 8]
        root = CH[name][1]
        _lofi_keys(bar, rng, cache[name], t_of, keys)
        _lofi_bass(bar, root, rng, t_of, beat, bas)
        _lofi_drums(bar, rng, t_of, drums)
        _lofi_melody(bar, rng, t_of, mel)
    # vinyl: faint hiss and sparse pops, wrapped
    hiss = dsp.lowpass(rng.standard_normal(keys.n), 6000) * 0.004
    pops = np.zeros(keys.n)
    for p in rng.integers(0, keys.n, int(mix_len * 1.4)):
        pops[p] = rng.choice((-1, 1)) * rng.random() ** 2
    pops = dsp.lowpass(pops, 4000) * 0.03
    vinyl = np.vstack([hiss + pops, np.roll(hiss, 997) + np.roll(pops, 41)])
    kb = keys.buf
    kb = dsp.lowpass(kb, 2900)
    kb = dsp.pingpong(kb, int(beat * 0.75 * SR), 0.18, 0.4, 3)
    mb = dsp.pingpong(mel.buf, int(beat * 0.75 * SR), 0.9, 0.55, 4)
    wet = dsp.reverb(kb + mb, 0.20)
    mixed = wet + bas.buf + dsp.lowpass(drums.buf, 7000) + vinyl
    return dsp.master(mixed)


PROG_E = [["Dmaj7"], ["Bm9"], ["Gmaj9"], ["A9"]]


def _electronic_arp(bar, rng, notes, pt, ga, timing, arp):
    bar_s, step = timing
    for s in range(16):
        if s % 4 == 0 or rng.random() < 0.8 * ga + 0.1:
            m = notes[pt[s] % 4] + 12 * (1 + (s // 8 + bar // 8) % 2)
            v = (1.0 if s % 4 == 0 else 0.65) * ga
            arp.add(dsp.ep(m + 0, 0.5, 0.35) * np.exp(-dsp.tt(0.5) / 0.1) * 1.0, bar * bar_s + s * step, -0.4 + 0.8 * (s % 2), 0.2 * v)


def _electronic_drums(bar, rng, gh, timing, drums):
    bar_s, beat = timing
    for b in range(4):
        drums.add(dsp.kick(0.8, 46, 110, 0.09), bar * bar_s + b * beat, 0, 0.42)
        drums.add(dsp.noise(rng, 0.06, 6500, 10000, 0.02), bar * bar_s + b * beat + beat / 2, 0.25, 0.07 * gh)
    for b in (1, 3):
        drums.add(dsp.snare(rng, 0.5), bar * bar_s + b * beat, 0.1, 0.12 * gh)


def electronic():
    rng = np.random.default_rng(2107)
    beat = 0.6
    nb = 40
    bar_s = 4 * beat
    T = nb * bar_s
    pad, arp, bas, drums = (Mix(T) for _ in range(4))
    step = beat / 4
    prog = ["Dmaj7", "A9", "Bm9", "Gmaj9"]
    pads = {}
    for name in prog:
        notes, root = CH[name]
        pads[name] = sum(dsp.saw_stack(m, bar_s + 1.0, (-11, 0, 11)) * np.clip(dsp.tt(bar_s + 1.0) / 0.25, 0, 1)
                         * np.clip((bar_s + 1.0 - dsp.tt(bar_s + 1.0)) / 0.9, 0, 1) for m in notes)
    cyc = lambda b, ph: 0.5 + 0.5 * np.cos(2 * np.pi * (b / nb - ph))
    pat = [[0, 2, 1, 3, 2, 1, 3, 2, 0, 2, 1, 3, 2, 3, 1, 2], [0, 1, 2, 1, 3, 2, 1, 0, 3, 2, 1, 2, 0, 1, 3, 1]]
    for bar in range(nb):
        name = prog[bar % 4]
        notes, root = CH[name]
        pad.add(pads[name], bar * bar_s, 0, 0.1)
        ga = 0.45 + 0.55 * cyc(bar, 0.25)
        gh = 0.35 + 0.65 * cyc(bar, 0.75)
        _electronic_arp(bar, rng, notes, pat[(bar // 2) % 2], ga, (bar_s, step), arp)
        for s in (2, 6, 10, 14):
            bas.add(dsp.bass(root, 0.28, 1.0), bar * bar_s + s * step, 0, 0.42)
        _electronic_drums(bar, rng, gh, (bar_s, beat), drums)
    # sidechain pump: duck pad, arp and bass on every kick
    tpos = (np.arange(pad.n) / SR) % beat
    duck = 1 - 0.38 * np.exp(-tpos / 0.14) * np.clip(tpos / 0.012, 0, 1)
    # pad filter breathes over 20 bars
    p = pad.buf
    lows, mids, highs = dsp.lowpass(p, 500), dsp.lowpass(p, 1200), dsp.lowpass(p, 2600)
    ph = np.arange(pad.n) / SR / (T / 2) * 2 * np.pi
    w = 0.5 + 0.5 * np.sin(ph)
    pb = (1 - w) * lows + w * (0.5 * mids + 0.5 * highs)
    pb = pb * duck
    ab = dsp.lowpass(arp.buf, 3000)
    ab = dsp.pingpong(ab, int(beat * 0.75 * SR), 0.7, 0.5, 5) * duck
    wet = dsp.reverb(pb + ab, 0.2)
    mixed = wet + bas.buf * duck + dsp.lowpass(drums.buf, 8000)
    return dsp.master(mixed)


def main():
    dsp.write("lofi", lofi())
    dsp.write("electronic", electronic())


if __name__ == "__main__":
    main()
