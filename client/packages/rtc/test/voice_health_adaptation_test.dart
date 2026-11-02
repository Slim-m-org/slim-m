// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The receive-side adaptation counters and our own echo readings reach the
/// minute line and the call summary, and say nothing when there is nothing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/src/audio_glitch_watch.dart';
import 'package:slimm_rtc/src/audio_stats.dart';
import 'package:slimm_rtc/src/call_stats.dart' show StatsEntry;
import 'package:slimm_rtc/src/voice_health.dart';

const _rate = 48000;

AudioReceiveSample _remote(
  int second, {
  num? discarded,
  num? accelerated,
  num? decelerated,
  num? silent,
}) =>
    AudioReceiveSample(
      totalSamples: second * 5 * _rate,
      packetsReceived: second * 250,
      clockRate: _rate,
      packetsDiscarded: discarded,
      removedSamplesForAcceleration: accelerated,
      insertedSamplesForDeceleration: decelerated,
      silentConcealedSamples: silent,
    );

AudioSendSample _sent(int second, {num? erl, num? erle}) => AudioSendSample(
      timestampMs: second * 5000,
      packetsSent: second * 250,
      bytesSent: second * 5000,
      echoReturnLoss: erl,
      echoReturnLossEnhancement: erle,
    );

/// A call of two 5 s intervals for each person, ended so the summary lines exist.
List<String> _summary({
  num? discarded,
  num? accelerated,
  num? decelerated,
  num? silent,
  Map<String, num>? quiet,
  num? erl,
  num? erle,
}) {
  final health = VoiceHealth();
  for (var i = 0; i < 3; i++) {
    health.observeRemote(
      'ann',
      'Ann',
      _remote(
        i,
        discarded: discarded == null ? null : discarded * i,
        accelerated: accelerated == null ? null : accelerated * i,
        decelerated: decelerated == null ? null : decelerated * i,
        silent: silent == null ? null : silent * i,
      ),
    );
    health.observeRemote(
      'bo',
      'Bo',
      _remote(
        i,
        discarded: quiet == null ? null : 0,
        accelerated: quiet == null ? null : 0,
        decelerated: quiet == null ? null : 0,
        silent: quiet == null ? null : 0,
      ),
    );
    health.observeLocal(
      'me',
      _sent(
        i,
        erl: erl,
        erle: erle,
      ),
    );
  }
  return health.finish();
}

String _line(List<String> lines, String needle) =>
    lines.firstWhere((l) => l.contains(needle), orElse: () => '');

void main() {
  group('the stats report', () {
    test('carries the adaptation counters and the echo readings', () {
      final entries = [
        const StatsEntry(
            type: 'outbound-rtp', id: 'o', values: {'kind': 'audio'}),
        const StatsEntry(
          type: 'media-source',
          id: 'm',
          values: {'echoReturnLoss': -12.5, 'echoReturnLossEnhancement': 8},
        ),
        const StatsEntry(
          type: 'inbound-rtp',
          id: 'i',
          values: {
            'kind': 'audio',
            'packetsDiscarded': 4,
            'removedSamplesForAcceleration': 960,
            'insertedSamplesForDeceleration': 480,
            'silentConcealedSamples': 96,
          },
        ),
      ];

      final send = parseAudioSend(entries)!;
      final receive = parseAudioReceive(entries)!;

      expect(send.echoReturnLoss, -12.5);
      expect(send.echoReturnLossEnhancement, 8);
      expect(receive.packetsDiscarded, 4);
      expect(receive.removedSamplesForAcceleration, 960);
      expect(receive.insertedSamplesForDeceleration, 480);
      expect(receive.silentConcealedSamples, 96);
    });

    test('leaves them null where the platform reports none', () {
      final entries = [
        const StatsEntry(
            type: 'outbound-rtp', id: 'o', values: {'kind': 'audio'}),
        const StatsEntry(
            type: 'media-source', id: 'm', values: {'audioLevel': 0.1}),
      ];

      expect(parseAudioSend(entries)!.echoReturnLoss, isNull);
    });

    test('the raw media source is one sorted line, or null without one', () {
      final line = describeMediaSource(const [
        StatsEntry(
          type: 'media-source',
          id: 'm',
          values: {'kind': 'audio', 'audioLevel': 0.25},
        ),
      ]);

      expect(line, 'audioLevel=0.25 kind=audio');
      expect(describeMediaSource(const []), isNull);
    });

    test('the raw media source is logged once, at debug level', () {
      final logged = <(String, LogLevel)>[];
      final note = MediaSourceNote();
      const entries = [
        StatsEntry(type: 'media-source', id: 'm', values: {'kind': 'audio'}),
      ];

      note
        ..note(const [], (m, {level = LogLevel.info}) => logged.add((m, level)))
        ..note(entries, (m, {level = LogLevel.info}) => logged.add((m, level)))
        ..note(entries, (m, {level = LogLevel.info}) => logged.add((m, level)));

      expect(logged, [('Media source stats: kind=audio', LogLevel.debug)]);
    });
  });

  group('the call summary', () {
    test('pools the totals and names a person only when theirs is above zero',
        () {
      final lines = _summary(
        discarded: 3,
        accelerated: 960,
        decelerated: 480,
        silent: 48,
        quiet: const {},
      );

      expect(
        _line(lines, 'call summary over'),
        contains('discarded=6 accel=40ms decel=20ms silent=2ms'),
      );
      expect(
        _line(lines, 'Ann:'),
        contains('discarded=6 accel=40ms decel=20ms silent=2ms'),
      );
      expect(_line(lines, 'Bo:'), isNot(contains('discarded')));
    });

    test('pooled totals show zeros when reported, nothing when not', () {
      final reported = _summary(discarded: 0, accelerated: 0, quiet: const {});
      final absent = _summary();

      expect(
        _line(reported, 'call summary over'),
        contains('discarded=0 accel=0ms'),
      );
      expect(_line(absent, 'call summary over'), isNot(contains('discarded')));
      expect(_line(absent, 'call summary over'), isNot(contains('accel')));
    });

    test('our own line carries the echo readings only when they exist', () {
      final with_ = _summary(erl: 14, erle: 6);
      final without = _summary();

      expect(_line(with_, 'you:'), contains('erl=14dB erle=6dB'));
      expect(_line(without, 'you:'), isNot(contains('erl')));
    });
  });

  group('the minute line', () {
    test('names the counters that moved and echo when reported', () {
      var now = DateTime(2026);
      final health = VoiceHealth(clock: () => now);
      health.takeMinuteLine();
      for (var i = 0; i < 3; i++) {
        health.observeRemote(
          'ann',
          'Ann',
          _remote(i, discarded: 2 * i, accelerated: 0, decelerated: 0),
        );
        health.observeLocal('me', _sent(i, erl: 11));
      }
      now = now.add(const Duration(minutes: 2));

      final line = health.takeMinuteLine()!;

      expect(line, contains('Ann:'));
      expect(line, contains('discarded=4'));
      expect(line, isNot(contains('accel=')));
      expect(line, contains('you: sent='));
      expect(line, contains('erl=11dB'));
      expect(line, isNot(contains('erle')));
    });

    test('is unchanged when nothing is reported', () {
      var now = DateTime(2026);
      final health = VoiceHealth(clock: () => now);
      health.takeMinuteLine();
      for (var i = 0; i < 3; i++) {
        health.observeRemote('ann', 'Ann', _remote(i));
      }
      now = now.add(const Duration(minutes: 2));

      final line = health.takeMinuteLine()!;

      expect(line, isNot(contains('discarded')));
      expect(line, isNot(contains('erl')));
    });
  });

  group('screen-share audio', () {
    test('is read on every few samples, under its own name and key', () async {
      var reads = 0;
      var shareReads = 0;
      var second = 0;
      final lines = <String>[];
      final watch = AudioGlitchWatch(
        sources: () => {
          'ann': () async {
            reads++;
            return _remote(second);
          },
        },
        shareSources: () => {
          'ann': () async {
            shareReads++;
            return _remote(second, silent: second * 10);
          },
        },
        nameOf: (id) => id == 'ann' ? 'Ann' : id,
        log: (m, {LogLevel level = LogLevel.info}) => lines.add(m),
      );

      for (; second < kShareSampleEvery * 2 + 1; second++) {
        await watch.sample();
      }
      watch.finish();

      expect(reads, kShareSampleEvery * 2 + 1);
      expect(shareReads, 2);
      expect(_line(lines, 'Ann (share):'), isNotEmpty);
      expect(_line(lines, 'Ann:'), isNotEmpty);
    });

    test('never flags a poor connection', () async {
      var second = 0;
      final watch = AudioGlitchWatch(
        sources: () => {},
        shareSources: () => {
          'ann': () async => AudioReceiveSample(
                totalSamples: second * 20 * _rate,
                concealedSamples: second * 20 * _rate * 0.9,
                clockRate: _rate,
              ),
        },
        log: (m, {LogLevel level = LogLevel.info}) {},
      );

      for (; second < kShareSampleEvery * 12; second++) {
        await watch.sample();
      }

      expect(watch.health.poorConnections.value, isEmpty);
    });
  });
}
