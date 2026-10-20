// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call's audio health: window math, a hint that does not flicker, the lines
/// a tester's exported log carries.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/src/audio_glitch_watch.dart';
import 'package:slimm_rtc/src/audio_stats.dart';
import 'package:slimm_rtc/src/call_stats.dart' show StatsEntry;
import 'package:slimm_rtc/src/voice_health.dart';
import 'package:slimm_rtc/src/voice_health_window.dart';

const _rate = 48000;

/// One remote reading [seconds] into the call; [concealed] is cumulative samples.
AudioReceiveSample _remote(
  double seconds, {
  double concealed = 0,
  double delay = 0,
  double lost = 0,
  double events = 0,
}) =>
    AudioReceiveSample(
      concealedSamples: concealed,
      concealmentEvents: events,
      totalSamples: seconds * _rate,
      packetsLost: lost,
      packetsReceived: seconds * 50,
      jitterSeconds: 0.01,
      clockRate: _rate,
      jitterBufferDelay: delay,
      jitterBufferEmittedCount: seconds * _rate,
      audioLevel: 0.1,
      rttMs: 30,
    );

/// Feeds [steps] intervals of [step] seconds, each concealing [share] of its samples.
void _feed(
  VoiceHealth health,
  List<double> shares, {
  double step = 5,
  String id = 'ann',
}) {
  var concealed = 0.0;
  var t = 0.0;
  health.observeRemote(id, 'Ann', _remote(0));
  for (final share in shares) {
    t += step;
    concealed += share * step * _rate;
    health.observeRemote(id, 'Ann', _remote(t, concealed: concealed));
  }
}

void main() {
  group('window math', () {
    test('a long clean interval outweighs a short bad one', () {
      final w = HealthWindow(const Duration(seconds: 60))
        ..add(const HealthInterval(
            seconds: 9, samples: 9 * _rate * 1.0, concealedSamples: 0))
        ..add(const HealthInterval(
            seconds: 1, samples: _rate * 1.0, concealedSamples: _rate * 0.5));
      expect(w.concealShare, closeTo(0.05, 1e-9));
    });

    test('intervals older than the span fall out', () {
      final w = HealthWindow(const Duration(seconds: 10));
      for (var i = 0; i < 5; i++) {
        w.add(HealthInterval(
          seconds: 5,
          samples: 5.0 * _rate,
          concealedSamples: i == 0 ? 5.0 * _rate : 0,
        ));
      }
      expect(w.seconds, 10);
      expect(w.concealShare, 0);
    });

    test('percentile is nearest rank', () {
      final v = [for (var i = 1; i <= 20; i++) i.toDouble()];
      expect(percentile(v, 0.5), 10);
      expect(percentile(v, 0.95), 19);
      expect(percentile(const <double>[], 0.5), isNull);
    });

    test('the jitter buffer is the delay over the samples it emitted', () {
      final health = VoiceHealth();
      health.observeRemote('ann', 'Ann', _remote(0));
      health.observeRemote('ann', 'Ann', _remote(5, delay: 9600));
      final line = health.finish().join('\n');
      // Each of 240000 emitted samples waited 40 ms on average.
      expect(line, contains('buffer p50=40ms'));
    });
  });

  group('parsing a raw report', () {
    test('reads the receive counters the wrapper drops', () {
      final sample = parseAudioReceive(const [
        StatsEntry(type: 'codec', id: 'c1', values: {'clockRate': 48000}),
        StatsEntry(type: 'inbound-rtp', id: 'i1', values: {
          'kind': 'audio',
          'codecId': 'c1',
          'concealedSamples': 480,
          'totalSamplesReceived': 96000,
          'jitterBufferDelay': 2.5,
          'jitterBufferEmittedCount': 96000,
          'audioLevel': 0.2,
        }),
        StatsEntry(type: 'candidate-pair', id: 'p', values: {
          'nominated': true,
          'currentRoundTripTime': 0.042,
        }),
      ]);
      expect(sample!.totalSamples, 96000);
      expect(sample.jitterBufferEmittedCount, 96000);
      expect(sample.clockRate, 48000);
      expect(sample.rttMs, closeTo(42, 1e-9));
    });

    test('reads a native report whose numbers arrive as strings', () {
      final sample = parseAudioReceive(const [
        StatsEntry(type: 'inbound-rtp', id: 'i', values: {
          'mediaType': 'audio',
          'concealedSamples': '480',
          'totalSamplesReceived': '96000',
          'jitterBufferDelay': '3.84',
          'jitterBufferEmittedCount': '96000',
        }),
      ]);
      expect(sample!.concealedSamples, 480);
      expect(sample.samples, 96000);
    });

    test('reads the publisher counters and the far end view of them', () {
      final sample = parseAudioSend(const [
        StatsEntry(type: 'outbound-rtp', id: 'o', timestampMs: 5000, values: {
          'kind': 'audio',
          'packetsSent': 250,
          'bytesSent': 20000,
        }),
        StatsEntry(type: 'media-source', id: 'm', values: {'audioLevel': 0.3}),
        StatsEntry(type: 'remote-inbound-rtp', id: 'r', values: {
          'kind': 'audio',
          'roundTripTime': 0.05,
          'packetsLost': 3,
        }),
      ]);
      expect(sample!.packetsSent, 250);
      expect(sample.audioLevel, 0.3);
      expect(sample.rttMs, closeTo(50, 1e-9));
      expect(sample.packetsLost, 3);
    });
  });

  group('the connection hint', () {
    test('stays off while audio is clean', () {
      final health = VoiceHealth();
      _feed(health, [0, 0.01, 0.0, 0.02]);
      expect(health.poorConnections.value, isEmpty);
    });

    test('shows after concealment is high for 5 seconds', () {
      final health = VoiceHealth();
      _feed(health, [0.0, 0.2]);
      expect(health.poorConnections.value, {'ann'});
    });

    test('a burst shorter than 5 seconds does not show it', () {
      final health = VoiceHealth();
      _feed(health, [0.0, 0.5, 0.0, 0.5, 0.0], step: 2);
      expect(health.poorConnections.value, isEmpty);
    });

    test('a hint that shows does not flicker on a good interval', () {
      final health = VoiceHealth();
      var changes = 0;
      health.poorConnections.addListener(() => changes++);
      _feed(health, [0.2, 0.0, 0.2, 0.0, 0.2, 0.04, 0.2]);
      expect(health.poorConnections.value, {'ann'});
      expect(changes, 1);
    });

    test('clears only after 10 seconds clearly good', () {
      final health = VoiceHealth();
      _feed(health, [0.2, 0.0]);
      expect(health.poorConnections.value, {'ann'});
      _feed(health, [0.2, 0.0, 0.0]);
      expect(health.poorConnections.value, isEmpty);
    });

    test('a muted gap is not counted as concealment', () {
      final health = VoiceHealth();
      health.observeRemote('ann', 'Ann', _remote(0));
      health.skip('ann');
      health.observeRemote('ann', 'Ann', _remote(60, concealed: 60.0 * _rate));
      health.observeRemote('ann', 'Ann', _remote(65, concealed: 60.0 * _rate));
      expect(health.poorConnections.value, isEmpty);
    });

    test('someone flagged poor who then mutes loses the hint', () {
      final health = VoiceHealth();
      _feed(health, [0.2, 0.2]);
      expect(health.poorConnections.value, {'ann'});
      health.skip('ann');
      expect(health.poorConnections.value, isEmpty);
    });

    test('someone who left no longer has a hint', () {
      final health = VoiceHealth();
      _feed(health, [0.2, 0.2]);
      health.retain({});
      expect(health.poorConnections.value, isEmpty);
    });

    test('a high round trip on our own audio marks us', () {
      final health = VoiceHealth();
      AudioSendSample at(int s) => AudioSendSample(
            timestampMs: s * 1000,
            packetsSent: s * 50,
            bytesSent: s * 4000,
            rttMs: 600,
          );
      health.observeLocal('me', at(0));
      health.observeLocal('me', at(5));
      expect(health.poorConnections.value, {'me'});
    });
  });

  group('the log', () {
    test('writes one line a minute with every measure, and not before', () {
      var now = DateTime(2026);
      final health = VoiceHealth(clock: () => now);
      _feed(health, [0.0, 0.1]);
      expect(health.takeMinuteLine(), isNull);
      now = now.add(const Duration(seconds: 59));
      expect(health.takeMinuteLine(), isNull);
      now = now.add(const Duration(seconds: 2));
      final line = health.takeMinuteLine()!;
      expect(line, isNot(contains('\n')));
      expect(line, startsWith('[voice-health] last 60s | Ann: conceal=5.0%'));
      for (final key in [
        'events=',
        'jitter=10ms',
        'buffer=',
        'loss=',
        'rtt=30ms'
      ]) {
        expect(line, contains(key));
      }
      expect(health.takeMinuteLine(), isNull);
    });

    test('the summary has p50 and p95 for the call and each person', () {
      final health = VoiceHealth();
      _feed(health, [0.0, 0.0, 0.0, 0.1]);
      final lines = health.finish();
      expect(lines, hasLength(2));
      expect(lines.first, contains('call summary over 20s'));
      expect(lines.first, contains('conceal p50=0.0% p95=10.0%'));
      expect(lines.first, contains('rtt p50=30ms p95=30ms'));
      expect(lines.last, contains('call summary Ann: over 20s'));
      expect(health.lastCall.value!.remote.concealP95, closeTo(0.1, 1e-9));
    });

    test('a call with nothing sampled writes nothing', () {
      expect(VoiceHealth().finish(), isEmpty);
    });

    test('the watch logs the summary when the call finishes', () async {
      final lines = <String>[];
      var t = 0.0;
      final watch = AudioGlitchWatch(
        sources: () => {'ann': () async => _remote(t, concealed: t * 100)},
        log: (m, {LogLevel level = LogLevel.info}) => lines.add(m),
      );
      await watch.sample();
      t = 5;
      await watch.sample();
      watch.finish();
      expect(lines.where((l) => l.contains('call summary')), isNotEmpty);
    });
  });
}
