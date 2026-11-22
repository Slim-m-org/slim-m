<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# GTCRN and DTLN against mouth sounds (2026-11-22)

Card: "Voice: a suppressor that removes mouth sounds at microphone level".
Follows `voice-transients-2026-11-02.md`, which found that a cough, wet chewing or a lip smack at microphone level passes Strong at -3 to -7 dB because rnnoise reads it as voice and DeepFilterNet reads it the same way.

## Verdict: no-go

Neither small model meets the bar (loud rows down 10 dB or more, speech within 1 dB, word onsets no worse than today).
Both do worse than rnnoise on the rows that matter, which is what we are trying to fix, so nothing is wired into the fork.

- GTCRN is about as good as rnnoise overall on the loud rows (mean -11.3 dB against -11.5 dB) and no better where it counts: wet chewing -2.2 dB, cough -3.1 dB, mouse click -0.7 dB, sip -2.1 dB, swallow -3.3 dB.
  Five of 15 clips still pass at 0 dB with less than 5 dB removed, against three for Strong.
  It costs 2.8% of a core here, over the 2% budget, against 0.64% for Strong.
- DTLN is worse than rnnoise on almost every loud row (mean -6.2 dB, eight of 15 clips under 5 dB removed) and also on the quiet rows.
  It costs 1.3% of a core.
- Speech and onsets are not the problem for either: -0.3 dB and -0.1 dB on speech, 0 of 7 word onsets clipped, as good as Strong.
  The models fail on removal, so the speech columns never decide it.

The three worst clips for every model, a cough, wet apple chewing and a mouse click, sit in the same place the 2026-11-02 note found for rnnoise.
The likely reason, not tested here, is that a model trained on speech plus generic noise has no reason to call a loud close-mic transient noise.
Training on the DNS challenge noise classes is evidently not enough; the training set would need mouth sounds as an explicit class, which I did not find documented for either model.

## What was run

- Harness: `scripts/research/mouth_transients_models.py` (new, research only).
  It reuses the case builder, level measures and alignment of `mouth_transients_offline.py`: the 15 CC0 clips from `scripts/lib/fetch_mouth_noise.py`, each laid in a silent tail after piper speech at clip gain -18, -6 and 0 dB, scored per clip as energy change over the clip's frames (out minus in, dB).
- Baseline: the fork's `strongest_tool` at the pinned commit 6e008df (release build, `strong` and `strongest`), through the same scoring.
  The baseline numbers match the 2026-11-02 note's tables.
- Models: run on CPU through onnxruntime 1.32.0 in a venv, one thread, causal frame by frame as they would run live.
  Both models are 16 kHz, so each case is resampled 48 to 16 kHz and back (polyphase, 3:1).
  Anything above 8 kHz is lost on the way, which would be a fidelity cost on top of everything below if one of them had passed.
- Nothing played or captured audio; everything ran offline against files.

## Models, licences, sources

| | GTCRN | DTLN |
|---|---|---|
| source | github.com/Xiaobin-Rong/gtcrn at 502ebfab64da7c4a9af78dcb9c6ceef1ebb01c73 | github.com/breizhn/DTLN at 1de1f15a8b5b7e1c44905618ff2ef70ca8277fbc |
| licence | MIT (repo LICENSE, Rong Xiaobin 2024) | MIT (repo LICENSE, Nils L. Westhausen 2020) |
| shipping fit | compatible with a PolyForm Noncommercial app, attribution notice needed | same |
| training data | DNS3 challenge (the `model_trained_on_dns3` checkpoint; the streaming ONNX is its export) | DNS3 challenge, 500 h (the README ties the pretrained ONNX to the 500 h model) |
| file used | `stream/onnx_models/gtcrn_simple.onnx`, 535190 bytes, sha256 b4718df6228e7bdf1a8a435cf98f838636eb2fd331acabf86ba87c5192ebcb87 | `pretrained_model/model_1.onnx` 1458237 bytes sha256 22b91cae3855e5a0620e66a917ca6c82c58db0e842c770f58d86751c5e8d4ae3, `model_2.onnx` 2510010 bytes sha256 e20c92f9233fccf29cddf86970d0d0161a03aebccc26d6f4d5639c4d5ec2e639 |
| size | 48.2 K parameters, 33 MMACs/s (README) | under 1 M parameters (README) |
| frame | 32 ms window, 16 ms hop | 32 ms block, 8 ms shift |
| CPU here, % of one core, inference calls only, one thread, onnxruntime | 2.8 (max 3.2) | 1.3 (max 1.4) |

CPU is the time inside the onnxruntime calls over the audio's duration, on a Ryzen 9 9950X3D, so a native integration would be in the same range plus framing.
Reference on the same machine from `deepfilternet-evaluation.md`: Strong 0.64%, Strongest 2.2% of a core.
GTCRN is therefore over the 2% budget by itself, before running beside rnnoise.

## Offline: energy change per clip, dB (more negative is better)

The 2026-11-02 tables are per clip in the same way.
`strong` and `strongest` are the fork's modes, `gtcrn` and `dtln` the candidates.
The summary rows give the mean, median and the weakest clip (the number closest to zero).

Clip gain 0 dB (peaks at -6 dBFS, a mouth at the microphone):

| clip | strong | strongest | gtcrn | dtln |
|---|---|---|---|---|
| breath | -19.8 | -16.6 | -11.7 | -17.4 |
| chew (chips) 462301 | -4.2 | -3.4 | -2.2 | -3.9 |
| chew 729595 | -15.1 | -18.3 | -23.7 | -12.9 |
| chew 805674 | -20.8 | -19.0 | -21.0 | -8.6 |
| chew 860365 | -29.0 | -16.4 | -20.7 | -18.1 |
| cough | -3.1 | -3.7 | -3.1 | -1.6 |
| chair creak | -8.5 | -9.8 | -12.5 | -5.1 |
| mouse click | -1.0 | -1.4 | -0.7 | -0.4 |
| sip | -10.2 | -5.3 | -2.1 | -1.4 |
| smack 232930 | -13.8 | -29.1 | -41.1 | -8.1 |
| smack 528195 | -6.5 | -9.1 | -9.1 | -2.2 |
| smack 861352 | -5.6 | -5.9 | -5.6 | -3.4 |
| swallow 239007 | -7.4 | -8.4 | -7.6 | -5.8 |
| swallow 383742 | -21.1 | -6.6 | -5.3 | -3.5 |
| swallow 667132 | -5.7 | -2.8 | -3.3 | -1.1 |
| mean / median / weakest | -11.5 / -8.5 / -1.0 | -10.4 / -8.4 / -1.4 | -11.3 / -7.6 / -0.7 | -6.2 / -3.9 / -0.4 |
| clips down 10 dB or more | 7 of 15 | 6 of 15 | 6 of 15 | 3 of 15 |

Clip gain -6 dB: mean / median / weakest `strong` -17.1 / -11.4 / -1.3, `strongest` -14.1 / -10.5 / -1.1, `gtcrn` -12.1 / -9.6 / -1.0, `dtln` -8.5 / -6.9 / -0.6.
Clip gain -18 dB: mean / median / weakest `strong` -31.2 / -28.8 / -6.9, `strongest` -30.8 / -29.5 / -6.2, `gtcrn` -22.1 / -20.5 / -5.1, `dtln` -17.4 / -17.1 / -6.4.

Per clip at -6 dB and -18 dB:

| clip | strong -6 | gtcrn -6 | dtln -6 | strong -18 | gtcrn -18 | dtln -18 |
|---|---|---|---|---|---|---|
| breath | -51.7 | -11.0 | -18.6 | -52.5 | -20.5 | -20.0 |
| chew (chips) 462301 | -4.4 | -2.4 | -4.1 | -6.9 | -5.8 | -6.4 |
| chew 729595 | -20.7 | -33.5 | -19.6 | -42.8 | -45.6 | -25.1 |
| chew 805674 | -26.7 | -25.5 | -14.3 | -48.3 | -42.1 | -24.8 |
| chew 860365 | -45.1 | -26.6 | -22.2 | -51.5 | -39.4 | -25.0 |
| cough | -3.6 | -3.0 | -2.9 | -12.4 | -13.9 | -13.6 |
| chair creak | -8.6 | -11.5 | -6.9 | -25.3 | -22.3 | -13.9 |
| mouse click | -1.3 | -1.0 | -0.6 | -54.9 | -5.1 | -12.4 |
| sip | -15.0 | -3.6 | -2.9 | -32.0 | -13.2 | -13.1 |
| smack 232930 | -13.0 | -21.7 | -2.5 | -17.6 | -17.8 | -11.3 |
| smack 528195 | -11.4 | -9.6 | -4.9 | -20.4 | -16.6 | -17.1 |
| smack 861352 | -9.2 | -9.0 | -7.3 | -28.8 | -24.4 | -21.0 |
| swallow 239007 | -10.6 | -10.3 | -9.6 | -27.5 | -27.5 | -23.9 |
| swallow 383742 | -28.2 | -8.9 | -7.2 | -28.9 | -22.4 | -19.2 |
| swallow 667132 | -7.2 | -3.7 | -3.5 | -18.7 | -14.5 | -14.7 |

## Speech and word onsets

Measured with the same cases as the clips: speech energy change over the voiced frames, and `voice_noise`'s onset loss (an onset after half a second of quiet that sits more than the drop threshold under the clean speech counts as clipped).
The speech row does not depend on the clip or the gain.

| | speech change dB | word onsets clipped (of 7) |
|---|---|---|
| strong (rnnoise) | -0.27 | 0 |
| strongest | -2.02 | 4 |
| gtcrn | -0.29 | 0 |
| dtln | -0.13 | 0 |

## What it would take, if the question comes back

- A model trained with mouth sounds as their own class; I found none documented among the small open models.
- Training or fine-tuning one ourselves on the corpus plus the owner's own recording (the card for a microphone sample from Settings), which is a project of its own and not an integration.
- Until then the available levers stay the ones in `voice-transients-2026-11-02.md`: the leveler after suppression and an auto gain that stays off under Strong.

## Reproducing

```sh
python3 -m venv ~/.slimm-scratch/mouth-venv && ~/.slimm-scratch/mouth-venv/bin/pip install numpy scipy onnxruntime
python3 scripts/lib/fetch_mouth_noise.py
~/.slimm-scratch/mouth-venv/bin/python scripts/research/mouth_transients_models.py GTCRN.onnx DTLN_1.onnx DTLN_2.onnx
~/.slimm-scratch/mouth-venv/bin/python scripts/research/mouth_transients_models.py GTCRN.onnx DTLN_1.onnx DTLN_2.onnx --tool strongest_tool
```
