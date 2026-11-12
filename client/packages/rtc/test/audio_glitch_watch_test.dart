// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A log line says when a burst of static was the network concealing loss.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/src/audio_glitch_watch.dart';
import 'package:slimm_rtc/src/voice_health.dart';

AudioReceiveSample _s({
  num concealed = 0,
  num seconds = 0,
  num lost = 0,
}) =>
    AudioReceiveSample(
      concealedSamples: concealed,
      durationSeconds: seconds,
      packetsLost: lost,
      jitterSeconds: 0.02,
      clockRate: 48000,
    );

void main() {
  test('clean audio logs nothing', () {
    expect(
        concealmentLine('Ann', _s(), _s(concealed: 100, seconds: 5)), isNull);
  });

  test('heavy concealment names the person, the share and the loss', () {
    final line = concealmentLine(
      'Ann',
      _s(),
      _s(concealed: 48000 * 2, seconds: 5, lost: 40),
    );
    expect(line, contains('Ann'));
    expect(line, contains('40% concealed'));
    expect(line, contains('40 packets lost'));
    expect(line, contains('jitter 20 ms'));
  });

  test('too short an interval proves nothing', () {
    expect(
      concealmentLine('Ann', _s(), _s(concealed: 48000, seconds: 0.5)),
      isNull,
    );
  });

  test('the watch logs a warning from two samples and forgets people who left',
      () async {
    final lines = <String>[];
    var step = 0;
    final watch = AudioGlitchWatch(
      sources: () => {
        'Ann': () async =>
            step == 0 ? _s() : _s(concealed: 48000 * 2, seconds: 5, lost: 10),
      },
      log: (m, {LogLevel level = LogLevel.info}) => lines.add(m),
    );

    await watch.sample();
    step = 1;
    await watch.sample();

    expect(lines, hasLength(1));
    expect(lines.single, contains('Ann'));
  });

  test('our own poor flag carries the identity as it is at sample time',
      () async {
    var identity = 'local';
    AudioSendSample at(int s) => AudioSendSample(
          timestampMs: s * 1000,
          packetsSent: s * 50,
          bytesSent: s * 4000,
          rttMs: 600,
        );
    var second = 0;
    final watch = AudioGlitchWatch(
      sources: () => {},
      local: () async => at(second),
      localIdOf: () => identity,
      log: (m, {LogLevel level = LogLevel.info}) {},
    );
    identity = 'me';

    await watch.sample();
    second = 5;
    await watch.sample();

    expect(watch.health.poorConnections.value, {'me'});
  });

  test('a healthy minute is noted for diagnostics but kept out of the log',
      () async {
    var now = DateTime(2026);
    var seconds = 0;
    final lines = <String>[];
    final notes = <String>[];
    final watch = AudioGlitchWatch(
      sources: () => {
        'Ann': () async => AudioReceiveSample(
              concealedSamples: 0,
              totalSamples: seconds * 48000,
              durationSeconds: seconds,
              packetsLost: 0,
              packetsReceived: seconds * 50,
              jitterSeconds: 0.005,
              clockRate: 48000,
            ),
      },
      health: VoiceHealth(clock: () => now),
      log: (m, {LogLevel level = LogLevel.info}) => lines.add(m),
      note: notes.add,
    );

    for (var i = 0; i < 15; i++) {
      await watch.sample();
      seconds += 5;
      now = now.add(const Duration(seconds: 5));
    }

    expect(notes.single, startsWith('[voice-health] last 60s'));
    expect(lines, isEmpty);
  });
}
