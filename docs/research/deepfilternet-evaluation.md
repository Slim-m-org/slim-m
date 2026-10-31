# DeepFilterNet as a "Strongest" desktop mode: offline evaluation

Written 2026-10-19.
Planka card 1885406385533880056.
Everything here is offline, on one machine, with no app or e2e stack involved.
Raw results are in `~/.slimm-scratch/tmp/report-ab/dfn/` (`results.json`, `summary.txt`, the processed audio under `raw/out`).
The scripts are in `scripts/research/` (`dfn_material.py`, `dfn_eval.py`, `rnn_cli.c`, `dfn_bench/`).

## Setup

- Material: piper TTS speech (voice A lessac, voice B ryan, seven sentences each, 2.6 s gaps), 48 kHz mono.
- Noises: fan, music (generated), babble (six piper utterances overlapped), typing, dog bark, door slam (generated).
  Fan, music and babble run the whole clip.
  Typing, bark and door land in each gap and on top of three sentences.
- SNR is noise RMS against speech active RMS: 20, 10 and 5 dB on voice A, 10 dB on voice B.
  26 clips, 44 s each.
- Processors, all fed 10 ms (480 sample) frames in order, the way the input gate sees them:
  - rnnoise: the exact source the fork vendors (`third_party/rnnoise` at flutter-webrtc a5d9427, rnnoise 0.2), built `gcc -O2`, the same `rnnoise_process_frame` call as `flutter_noise_suppressor.cc`.
  - DeepFilterNet3: libDF 0.5.6 (`deep_filter` crate, tract runtime, the default DFN3 model, 10 ms hop, 20 ms window), run frame by frame.
    Post-filter off, and a variant with post-filter beta 0.02 (`dfn3pf`).
- Not included: the fork's gate, compressor and limiter, and libwebrtc's own AEC, NS and AGC.
  Both suppressors would sit behind the same ones in the real path.
- Delay is measured from clean speech through each processor and removed before scoring.
- Scores: ViSQOL (google/visqol 38d0b01, speech mode, ceiling 4.58) and PESQ wideband against the clean speech.
  Gap attenuation is the fall in gap level (power mean of 10 ms frames, 0.3 s margin around speech, or the event windows for typing, bark and door) from the noisy input to the output.
  Onset clipping counts word starts after at least 0.5 s of quiet that lose 30 ms or more in their first 200 ms (a frame counts when it is more than 10 dB under the clean speech), the metric of the voice harness v2.

## Numbers

Means over the 20 clips of voice A (3 SNRs for each noise), except where noted.
`none` is the unprocessed noisy input.

| measure | none | rnnoise | DFN3 | DFN3 + post-filter |
|---|---|---|---|---|
| ViSQOL, clean speech A / B | 4.60 / 4.47 | 4.60 / 4.51 | 3.77 / 3.74 | 3.77 / 3.72 |
| PESQ, clean speech A / B | 4.64 / 4.64 | 4.58 / 4.58 | 2.76 / 3.90 | 2.75 / 3.87 |
| ViSQOL, all noisy, SNR 20 / 10 / 5 | 3.17 / 2.75 / 2.62 | 4.02 / 3.37 / 3.02 | 3.54 / 3.43 / 3.22 | 3.43 / 3.38 / 3.12 |
| PESQ, all noisy, SNR 20 / 10 / 5 | 2.42 / 1.86 / 1.76 | 3.05 / 2.35 / 2.05 | 2.25 / 2.15 / 1.86 | 2.17 / 2.09 / 1.82 |
| gap attenuation dB, fan | 0 | 26.7 | 50.4 | 54.7 |
| gap attenuation dB, music | 0 | 7.2 | 22.6 | 23.1 |
| gap attenuation dB, babble | 0 | 8.3 | 16.3 | 16.7 |
| gap attenuation dB, typing | 0 | 2.1 | 13.6 | 13.7 |
| gap attenuation dB, dog bark | 0 | 0.0 | 7.6 | 7.6 |
| gap attenuation dB, door slam | 0 | 9.9 | 31.7 | 32.7 |
| bark, SNR 20 / 10 / 5 | 0 | 0 / 0 / 0 | 11.7 / 5.9 / 4.6 | |
| speech level change dB (fan / babble) | | -0.4 / -0.9 | -0.7 / -4.5 | -0.7 / -4.8 |
| clipped onsets, noisy clips (of 168) | 0 | 2 | 55 | 60 |
| clipped onsets, clean speech (of 14) | 0 | 0 | 1 | 1 |
| mean onset loss ms, noisy / clean | 0 | 1.1 / 0 | 23 / 4 | 25 / 4 |
| added latency ms (measured) | 0 | 20 | 30 | 30 |
| CPU, one 48 kHz stream, % of one core | 0 | 0.64 | 1.4 | 1.5 |
| worst 10 ms frame, ms (p99 / max) | | not timed | 0.39 / 0.62 | 0.40 / 0.47 |
| memory (RSS, tiny input) | | 3.5 MB | 48 MB | 48 MB |
| added to the binary (stripped) | | 1.5 MB (1.2 MB gzip) | about 21 MB (about 12 MB gzip) | same |
| model weights | | inside the 1.5 MB | 8.6 MB ONNX (8 MB tar.gz), 3 files | same |

Voice B at SNR 10 (one clip per noise) tells the same story: gap attenuation for DFN3 against rnnoise is fan 44 / 27, music 23 / 6, babble 15 / 7, typing 13 / 3, bark 8 / 0, door 30 / 17 dB.

CPU model: AMD Ryzen 9 9950X3D, one thread pinned with `taskset`, 282 s of audio per run, three runs, spread under 3%.
Model load takes 60 ms.

## What this says

- DFN3 removes much more of everything that is not a steady hum.
  Typing goes from about 2 dB (rnnoise) to about 14 dB, music and door slams to 22 to 32 dB, and the fan to 50 dB and more.
  The dog bark, the case that started this, only goes from 0 to about 5 to 12 dB, and the quieter it is against the speech the less DFN3 removes.
  It is better than rnnoise and not a fix: a bark at 10 dB under the voice still comes through at about 6 dB under what was sent.
- Babble is unsolved by both (ViSQOL about 2.0 for DFN3 and rnnoise), and DFN3 takes 4.5 dB off the speech there because it cannot tell the voices apart.
- DFN3 costs speech quality that rnnoise does not.
  Clean speech scores 3.7 ViSQOL against 4.6, and at SNR 20 rnnoise scores higher on both metrics (4.02 against 3.54).
  DFN3 wins on ViSQOL at SNR 10 and 5 only by 0.06 and 0.2 points, and on PESQ rnnoise leads at every SNR.
  PESQ is also voice-dependent: DFN3 gets 2.8 on voice A and 3.9 on voice B for clean speech.
  Voice A has digital silence between words, which PESQ punishes any added low-level texture on, so PESQ here is pessimistic for DFN3 and I would trust ViSQOL more.
- Word onsets are the real cost.
  DFN3 clipped 55 of 168 word starts by 30 ms or more after a noisy gap, against 2 for rnnoise, and about 23 ms lost on average.
  The same effect shows in the harness v2 numbers for Strong under loss, so the two would stack with the gate.
  Quiet clean speech is nearly untouched (1 of 14).
- The post-filter adds 1 to 4 dB of attenuation and costs about 0.1 ViSQOL and a few more onsets, so it is not worth it by default.
- Latency is 30 ms against 20 ms, so +10 ms over Strong today.
  That comes from the 20 ms window plus lookahead of two frames, and the model cannot go lower without the low-latency model, which is 36 MB.
- CPU is small on this machine: 1.4% of one core, worst frame 0.4 ms of a 10 ms budget.
  Memory is the larger cost at 48 MB resident, against 3.5 MB for rnnoise.

## Weak laptop

I could not measure one.
Scaling by single-thread speed, a dual-core laptop CPU four to eight times slower than this one would run about 6 to 12% of a core, with a worst frame near 3 ms of 10 ms.
That is fine for the audio thread alone but it competes with video encode and screen share on that class of machine, and the 48 MB is minor but not free.
Tract picks AVX2 and FMA kernels at runtime, so a CPU without them (old Atom or Celeron) falls back to slower code that I did not measure.

## Recommendation

Ship it as an opt-in "Strongest" mode on Linux and Windows desktop, off by default, and do not make it the default for Strong.
It is the only option here that helps with typing, door slams, music and quiet-to-moderate barks, and the cost on a current machine is small.
Do not promise barks: it halves them at best, and babble not at all.
Do not ship it without fixing the onset clipping first, because a mode called "Strongest" that eats the start of sentences will read as broken.

- Platforms: Linux and Windows first, because the gate in the fork covers only those.
  macOS has no fork gate and no rnnoise today (web, macOS, iOS, Android all use the platform suppressor), so a macOS mode needs the same native step added first and is a separate card.
  Mobile: no, battery and memory.
- Integration: a second suppressor beside `flutter_noise_suppressor.cc` in the fork's capture chain, selected by the same `setInputGate` call (a `strength` value instead of the boolean).
  Build libDF as a static library with a small C interface (create, process one 480 sample frame, free); I measured a three-function wrapper at 22 MB linked.
  The input is the gate's existing 10 ms mono 48 kHz frames, so no resampling is needed.
  Run it before the gate and keep the gate's lookahead; rnnoise's speech probability for the gate would have to come from somewhere else (DFN3 exposes its local SNR, `process` returns it, and that is the obvious substitute).
- Build impact: a Rust toolchain in the fork's build for all three desktop targets, and one more static library to link against the prebuilt libwebrtc.
  tract is pure Rust, so there is no new C dependency, but the fork would need `cargo` in its CI on ubuntu and windows runners and a cross build if Windows arm64 is wanted.
  Expect about 21 MB more per desktop binary (12 MB zipped), and about 45 MB more memory while the mode is on; the model could be loaded only when the mode is enabled to avoid it otherwise.
- Licence: DeepFilterNet code is MIT or Apache-2.0 at our choice, and the pretrained DFN3 weights are in the same repository under the same terms with no separate model licence that I found.
  Both are compatible with shipping, with attribution in the notices file.
  The training data (the DNS Challenge and other corpora) has its own terms and I did not audit them; someone should read the paper's data section before a release.
  tract is MIT or Apache-2.0 too.
- Before shipping: reduce the onset clipping (try a longer gate hold, or a short lookahead bypass for the first frames after silence), re-run this evaluation on real recorded speech, and run the desktop path of the voice harness v2 with the new mode as a fifth arm.

## Not verified

- No human speech: both voices are TTS, and PESQ in particular behaves differently on TTS with digital silence.
  No listening test was done.
- The noises are generated, not recorded.
  The bark is a two-formant synthesis and a real dog may behave differently.
- Not run through the fork: no real capture chain, no gate, no echo cancellation, no network loss.
  The onset numbers are suppressor alone and the gate would add to them.
- No weak laptop, no Windows or macOS, no ARM: CPU and memory are from one Zen 5 Linux machine.
  The rnnoise number is a generic `-O2` build, not the fork's exact compiler flags.
- Memory is the peak resident size of the test program on a 1 s input, so it includes the program's own overhead.
- The binary size is from a probe linked against a three-function wrapper, not the fork.
- Delay was measured once per processor from the cross-correlation of clean speech, to the nearest sample.

## Onset clipping fix (v120)

Written 2026-10-28.
The decision was to build "Strongest" only once the word-start clipping above was handled, so this is what was done and measured before it shipped.
The code is in the flutter-webrtc fork (`common/cpp/src/flutter_noise_suppressor.cc`, `flutter_onset_cover.cc`, branch `v120/dfn`), and `scripts/research/dfn_onset_score.py` scores a variant with the method above (the fork's `test/native/strongest_tool` runs the real suppressor over each clip, 10 ms at a time).

Why DeepFilterNet clips.
It decides per frame, from a local SNR it estimates, whether to apply its mask, and the first frames of a word after a quiet spell look like the noise before them.
Its attenuation limit and stage thresholds are the model's own knobs and they do not help on their own:

| variant | clipped onsets (of 168) | mean onset loss ms | fan gap dB | typing gap dB |
|---|---|---|---|---|
| rnnoise | 2 | 1.2 | 26.5 | 1.7 |
| DFN3 as evaluated | 55 | 22.9 | 52.5 | 13.6 |
| DFN3, attenuation limit 12 dB | 1 of 126 (voice A only) | 1.1 | 12.0 | 9.3 |
| DFN3, attenuation limit 20 dB | 19 of 126 | 11.8 | 20.0 | 12.2 |
| DFN3, never zero a frame (min threshold -100) | 34 of 126 | 21.0 | 41.0 | 12.6 |
| DFN3 with onset cover (shipped) | 6 | 3.3 | 50.0 | 12.1 |

A 12 dB limit stops the clipping by giving up the whole point of the mode, so it is not an option.

What ships.
rnnoise keeps running beside DeepFilterNet, as it already does for Strong, and gives the gate its speech probability.
DeepFilterNet's output trails its input by three frames, so rnnoise's probability is three frames ahead of the audio it steers.
When that probability stays above 0.5 for five frames in a row after at least 200 ms without that, the output switches to rnnoise's own for 200 ms from the word start and fades back over 100 ms.
While the same speech goes on, half of the output stays rnnoise's.
Both only apply to a frame where rnnoise's output is louder than -50 dBFS and DeepFilterNet's is at least 2 dB under it, so noise at the floor and frames the two agree on are left to DeepFilterNet.
The five frames fit inside the three frames of lead plus the cover's own start, so a single click or door slam does not count as a word and the cost is the first 10 to 20 ms of the cover.
The first 500 ms after capture opens never cover, because rnnoise reads its own start-up as speech.

Numbers, same 26 clips, same scoring as the table above (6 of 168 is 3.6%, rnnoise's 2 is 1.2%, the unfixed mode's 55 is 33%):

| measure | rnnoise | DFN3 as evaluated | Strongest with cover |
|---|---|---|---|
| clipped onsets, noisy clips (of 168) | 2 | 55 | 6 |
| mean onset loss ms | 1.2 | 22.9 | 3.3 |
| gap attenuation dB: fan / music / babble | 26.5 / 7.5 / 8.6 | 52.5 / 22.3 / 16.5 | 50.0 / 13.2 / 13.2 |
| gap attenuation dB: typing / door / bark | 1.7 / 7.6 / 0.0 | 13.6 / 32.4 / 7.4 | 12.1 / 32.4 / 1.4 |
| speech level change dB (fan / babble) | -0.4 / -0.9 | -0.7 / -5.4 | -0.7 / -3.8 |
| added latency ms | 20 | 30 | 30 |

Cost of the fix, to say it plainly.
Where an onset and a noise look the same to rnnoise, the cover gives that noise to rnnoise: dog barks go from 7.4 to 1.4 dB of attenuation, music from 22 to 13, babble from 16.5 to 13.2.
Typing, door slams and the fan keep nearly all of DeepFilterNet's advantage, which is most of what the mode is for.
The sweep that picked these values (voice A, 126 onsets): with three confirm frames the cover clips 3 of 126 but gives up 14 dB of door and 5 dB of typing attenuation, and with five it clips 4 and keeps both; a continuing weight of 0.25, 0.4, 0.5 and 0.6 clipped 7, 4, 3 and 3 with three confirm frames.
Of the 6 remaining clipped onsets, 4 are in the fan clips and 2 in the babble clips.

Cost on this machine (AMD Ryzen 9 9950X3D, one thread), the whole Strongest path including rnnoise and the blend: 2.2% of one core at 10 ms frames, against 0.64% for Strong alone, measured with `strongest_tool`.

Size in the real plugin: the Linux release `libflutter_webrtc_plugin.so`, stripped, goes from about 2.6 MB to 26.4 MB (15 MB gzipped), against about 21 MB predicted from the probe; the Rust side keeps panic unwinding so a failed frame falls back to rnnoise instead of aborting the app.
