// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice ping: the round trip of the selected candidate pair, in whole
/// milliseconds, published only while samples are flowing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/audio_stats.dart';
import 'package:slimm_rtc/src/call_stats.dart' show StatsEntry;
import 'package:slimm_rtc/src/voice_health.dart';

StatsEntry _pair(String id, Map<String, Object?> values) =>
    StatsEntry(type: 'candidate-pair', id: id, values: values);

void main() {
  group('candidatePairRttMs', () {
    test('reads the pair the transport selected, in milliseconds', () {
      final entries = [
        _pair('a', {'currentRoundTripTime': 0.9, 'state': 'succeeded'}),
        _pair('b', {'currentRoundTripTime': 0.042, 'state': 'succeeded'}),
        const StatsEntry(
          type: 'transport',
          id: 't',
          values: {'selectedCandidatePairId': 'b'},
        ),
      ];
      expect(candidatePairRttMs(entries), closeTo(42, 1e-9));
    });

    test('falls back to a nominated pair and ignores failed ones', () {
      final entries = [
        _pair('a', {'currentRoundTripTime': 0.5, 'state': 'failed'}),
        _pair('b', {'currentRoundTripTime': 0.07, 'nominated': true}),
      ];
      expect(candidatePairRttMs(entries), closeTo(70, 1e-9));
    });

    test('is null when no pair reports a round trip', () {
      expect(candidatePairRttMs(const []), isNull);
      expect(
        candidatePairRttMs([
          _pair('a', {'state': 'succeeded'})
        ]),
        isNull,
      );
    });

    test('parseAudioSend carries it as pingMs beside the stream rtt', () {
      final sample = parseAudioSend([
        const StatsEntry(type: 'outbound-rtp', id: 'o', values: {
          'kind': 'audio',
        }),
        const StatsEntry(type: 'remote-inbound-rtp', id: 'r', values: {
          'kind': 'audio',
          'roundTripTime': 0.2,
        }),
        _pair('a', {'currentRoundTripTime': 0.031, 'nominated': true}),
      ])!;
      expect(sample.pingMs, closeTo(31, 1e-9));
      expect(sample.rttMs, closeTo(200, 1e-9));
    });
  });

  group('VoiceHealth.pingMs', () {
    test('rounds the local reading, then clears when sampling stops', () {
      final health = VoiceHealth();
      expect(health.pingMs.value, isNull);
      health.observeLocal(
        'me',
        const AudioSendSample(timestampMs: 0, pingMs: 41.6),
      );
      expect(health.pingMs.value, 42);
      health.clearPing();
      expect(health.pingMs.value, isNull);
    });

    test('falls back to a remote reading when we publish nothing', () {
      final health = VoiceHealth();
      health.observeRemote(
        'ann',
        'Ann',
        const AudioReceiveSample(totalSamples: 0, rttMs: 55),
      );
      expect(health.pingMs.value, 55);
    });
  });
}
