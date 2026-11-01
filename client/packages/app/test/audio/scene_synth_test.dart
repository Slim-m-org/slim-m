// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `scene_synth.dart` claims to be a faithful port of `assets/audio/synth.py`'s
/// `bell` and `render`. This is what actually holds the two together: both
/// sides render the identical note list, and `fixtures/scene_synth_fixture.
/// json` carries what the Python original produced, so a change to either
/// renderer that drifts from the other fails here rather than only sounding
/// different on a device.
///
/// The fixture was produced by running `assets/audio/synth.py`'s `bell` and
/// `render` directly (no normalisation - this file never claims to port
/// that) over the two notes below; regenerate it the same way if `synth.py`'s
/// partials or envelope ever change on purpose.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/scene_synth.dart';

void main() {
  final fixture =
      jsonDecode(
            File('test/fixtures/scene_synth_fixture.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  final notes = [
    for (final raw in fixture['notes'] as List<dynamic>)
      SynthNote(
        frequency: (raw['f'] as num).toDouble(),
        start: (raw['t'] as num).toDouble(),
        seconds: (raw['d'] as num).toDouble(),
      ),
  ];

  List<double> expected(String key) => (fixture[key] as List<dynamic>)
      .cast<num>()
      .map((n) => n.toDouble())
      .toList();

  test('sampleRate matches synth.py\'s SAMPLE_RATE', () {
    expect(sampleRate, fixture['sample_rate']);
  });

  test('bell agrees with synth.bell for the fixture note', () {
    final actual = bell(notes.first);
    final want = expected('bell_of_first_note');
    expect(actual.length, want.length);
    for (var i = 0; i < want.length; i++) {
      expect(actual[i], closeTo(want[i], 1e-9), reason: 'sample $i');
    }
  });

  test('render agrees with synth.render for the fixture notes', () {
    final actual = render(notes);
    final want = expected('render');
    expect(actual.length, want.length);
    for (var i = 0; i < want.length; i++) {
      expect(actual[i], closeTo(want[i], 1e-9), reason: 'sample $i');
    }
  });

  test('encodeWav16 produces a well-formed mono 16-bit header', () {
    final wav = encodeWav16(render(notes));
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    final byteData = wav.buffer.asByteData();
    expect(byteData.getUint16(22, Endian.little), 1, reason: 'mono');
    expect(byteData.getUint32(24, Endian.little), sampleRate);
    expect(byteData.getUint16(34, Endian.little), 16, reason: 'bit depth');
  });

  test('render renders silence for an empty note list', () {
    expect(render(const []), isEmpty);
  });
}
