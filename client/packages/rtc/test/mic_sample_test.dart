// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The raw sample's WAV framing, file name and countdown over a fake tap.
library;

import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

class _Tap implements MicSampleSource {
  _Tap(this.chunks);

  final List<MicSampleChunk> chunks;
  final calls = <String>[];
  Object? openError;

  @override
  Future<void> open(String? deviceId) async {
    calls.add('open:$deviceId');
    if (openError != null) throw openError!;
  }

  @override
  Future<void> start(int seconds) async => calls.add('start:$seconds');

  @override
  Future<MicSampleChunk> take() async =>
      chunks.isEmpty ? MicSampleChunk(pcm: Uint8List(0)) : chunks.removeAt(0);

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> close() async => calls.add('close');
}

Uint8List _second(int value) {
  final bytes = ByteData(kMicSampleRateHz * 2);
  for (var i = 0; i < kMicSampleRateHz; i++) {
    bytes.setInt16(i * 2, value, Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  test('the WAV is a mono 16-bit 48 kHz file around the samples', () {
    final pcm = Uint8List.fromList([1, 0, 255, 127, 0, 128]);
    final wav = wavFromPcm16(pcm);
    final view = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 16)), 'WAVEfmt ');
    expect(view.getUint32(4, Endian.little), 36 + pcm.length);
    expect(view.getUint16(20, Endian.little), 1);
    expect(view.getUint16(22, Endian.little), 1);
    expect(view.getUint32(24, Endian.little), 48000);
    expect(view.getUint32(28, Endian.little), 96000);
    expect(view.getUint16(34, Endian.little), 16);
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    expect(view.getUint32(40, Endian.little), pcm.length);
    expect(wav.sublist(44), pcm);
  });

  test('the file name carries the platform and the date', () {
    expect(
      micSampleFileName(DateTime(2026, 11, 2, 9, 5, 7), 'windows'),
      'mic-sample-windows-2026-11-02-090507.wav',
    );
  });

  test('records the goal, counts down and closes the capture', () {
    fakeAsync((async) {
      final tap =
          _Tap([for (var s = 0; s < 3; s++) MicSampleChunk(pcm: _second(7))]);
      final recorder = MicSampleRecorder(source: tap, seconds: 3);
      final seen = <int>[];
      recorder.progress.listen((p) => seen.add(p.remaining));
      Uint8List? wav;
      recorder.record('mic-1').then((v) => wav = v);
      async.elapse(const Duration(seconds: 2));
      expect(wav, isNotNull);
      expect(seen, [3, 2, 1, 0]);
      expect(wav!.length, 44 + 3 * kMicSampleRateHz * 2);
      expect(tap.calls, ['open:mic-1', 'start:3', 'stop', 'close']);
    });
  });

  test('a microphone that gives nothing fails instead of saving silence', () {
    fakeAsync((async) {
      final tap = _Tap([]);
      final recorder = MicSampleRecorder(source: tap, seconds: 3);
      Object? failure;
      recorder.record(null).catchError((Object e) {
        failure = e;
        return Uint8List(0);
      });
      async.elapse(const Duration(seconds: 6));
      expect(failure, isA<MicSampleException>());
      expect(tap.calls.last, 'close');
    });
  });

  test('a capture the tap could not bring to 48 kHz is refused', () {
    fakeAsync((async) {
      final tap = _Tap([MicSampleChunk(pcm: _second(1), skippedFrames: 4)]);
      final recorder = MicSampleRecorder(source: tap, seconds: 3);
      Object? failure;
      recorder.record(null).catchError((Object e) {
        failure = e;
        return Uint8List(0);
      });
      async.elapse(const Duration(seconds: 1));
      expect(failure, isA<MicSampleException>());
    });
  });

  test('a microphone that will not open says so', () {
    fakeAsync((async) {
      final tap = _Tap([])..openError = StateError('busy');
      Object? failure;
      MicSampleRecorder(source: tap).record(null).catchError((Object e) {
        failure = e;
        return Uint8List(0);
      });
      async.flushMicrotasks();
      expect(failure.toString(), contains('would not open'));
      expect(tap.calls, ['open:null', 'stop', 'close']);
    });
  });
}
