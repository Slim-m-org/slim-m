// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A faithful Dart port of `assets/audio/synth.py`'s `bell` and `render`: the
/// same three partials, the same envelope shape, the same sample rate.
///
/// Ported rather than reinvented so a module's sound shares one timbre with
/// the app's own notification chimes - the point is that the whole product
/// sounds like one thing, not that this file happens to also make a bell
/// noise. `test/scene_synth_test.dart` checks this against a fixture rendered
/// by the Python original, so a change to either side that drifts the other
/// fails there rather than only sounding different.
///
/// Deliberately NOT ported: `synth.py`'s loudness work (`_k_weighted`,
/// `loudness`, `normalise`, `pyloudnorm`). That machinery levels the seven
/// notification sounds against each other at build time, using a whole-clip
/// analysis and an offline library; a module's cue is rendered on a device in
/// response to a tap and has no such reference set to level against. The
/// clip-to-range step [encodeWav16] does is the ordinary "do not overflow a
/// 16-bit sample" safety [synth.write_wav] already does regardless of
/// normalisation, not a substitute for the LUFS work.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Must match `SAMPLE_RATE` in `assets/audio/synth.py` exactly - this is a
/// port of that renderer, not an independent one.
const sampleRate = 48000;

/// One note to render: mirrors `synth.Note` minus its `gain` field, which the
/// scene contract never carries; see `module_scene.dart`'s `SceneNote`.
class SynthNote {
  const SynthNote({
    required this.frequency,
    required this.start,
    required this.seconds,
  });

  final double frequency;
  final double start;
  final double seconds;
}

/// `synth.py`'s `_PARTIALS`: a fundamental plus two slightly inharmonic
/// overtones. Copied verbatim, not by eye - keep this and `_PARTIALS` in
/// lockstep, since the fixture test is what actually holds them together.
const _partials = <(double multiple, double amplitude)>[
  (1.0, 1.00),
  (2.02, 0.24),
  (3.05, 0.08),
];

/// Mirrors `synth._envelope`: a linear 12ms attack, then an exponential decay
/// tuned so the note has faded to about 1% of its peak by [seconds].
Float64List _envelope(int samples, double seconds) {
  final out = Float64List(samples);
  final decayRate = 4.6 / seconds;
  for (var i = 0; i < samples; i++) {
    final t = seconds * i / samples;
    final attack = (t / 0.012).clamp(0.0, 1.0);
    out[i] = attack * math.exp(-t * decayRate);
  }
  return out;
}

/// Mirrors `synth.bell`: one note of the shared timbre.
Float64List bell(SynthNote note) {
  final samples = (note.seconds * sampleRate).round();
  final voice = Float64List(samples);
  for (final (multiple, amplitude) in _partials) {
    final angular = 2.0 * math.pi * note.frequency * multiple;
    for (var i = 0; i < samples; i++) {
      final t = note.seconds * i / samples;
      voice[i] += amplitude * math.sin(angular * t);
    }
  }
  final envelope = _envelope(samples, note.seconds);
  for (var i = 0; i < samples; i++) {
    voice[i] *= envelope[i];
  }
  return voice;
}

/// Mirrors `synth.render`: lays every note onto one timeline, summing where
/// notes overlap. Empty input renders silence rather than the `ValueError`
/// the Python `max()` would raise - a defensive difference, not a behavioural
/// one, since a module never gets here with an empty note list (see
/// `NotesOp`'s own parsing).
Float64List render(List<SynthNote> notes, {double tail = 0.05}) {
  if (notes.isEmpty) return Float64List(0);
  var end = 0.0;
  for (final note in notes) {
    final noteEnd = note.start + note.seconds;
    if (noteEnd > end) end = noteEnd;
  }
  end += tail;
  final out = Float64List((end * sampleRate).round());
  for (final note in notes) {
    final rendered = bell(note);
    final at = (note.start * sampleRate).round();
    for (var i = 0; i < rendered.length && at + i < out.length; i++) {
      out[at + i] += rendered[i];
    }
  }
  return out;
}

/// Mirrors `synth.write_wav`'s sample encoding (clip to full scale, round to
/// 16-bit PCM) and wraps it in a standard mono WAV header, so the result is
/// something `audioplayers`' `BytesSource` can play with no file ever
/// touching disk. Not a port of the loudness normalisation that precedes
/// `write_wav` in the Python pipeline - see this file's own doc comment.
Uint8List encodeWav16(Float64List signal) {
  final samples = Int16List(signal.length);
  for (var i = 0; i < signal.length; i++) {
    final clipped = signal[i].clamp(-1.0, 1.0);
    samples[i] = (clipped * 32767.0).round();
  }
  final dataBytes = samples.buffer.asUint8List();
  const bytesPerSample = 2;
  const byteRate = sampleRate * bytesPerSample;
  final out = BytesBuilder();
  out.add(_ascii('RIFF'));
  out.add(_uint32le(36 + dataBytes.length));
  out.add(_ascii('WAVE'));
  out.add(_ascii('fmt '));
  out.add(_uint32le(16));
  out.add(_uint16le(1));
  out.add(_uint16le(1));
  out.add(_uint32le(sampleRate));
  out.add(_uint32le(byteRate));
  out.add(_uint16le(bytesPerSample));
  out.add(_uint16le(16));
  out.add(_ascii('data'));
  out.add(_uint32le(dataBytes.length));
  out.add(dataBytes);
  return out.toBytes();
}

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);

Uint8List _uint32le(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

Uint8List _uint16le(int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little);
