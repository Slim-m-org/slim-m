// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Parsing a stats report, and sampling only while someone is looking.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_rtc/rtc.dart';

StatsEntry _outbound(String rid, int w, int h, num bytes, num at) => StatsEntry(
      type: 'outbound-rtp',
      id: 'out-$rid',
      timestampMs: at,
      values: {
        'kind': 'video',
        'rid': rid,
        'frameWidth': w,
        'frameHeight': h,
        'framesPerSecond': 29.5,
        'bytesSent': bytes,
        'targetBitrate': 1700000,
        'codecId': 'codec-1',
        'encoderImplementation': 'libvpx',
        'powerEfficientEncoder': false,
        'qualityLimitationReason': 'bandwidth',
        'qualityLimitationResolutionChanges': 2,
        'keyFramesEncoded': 4,
        'active': true,
      },
    );

const _codec = StatsEntry(
  type: 'codec',
  id: 'codec-1',
  values: {'mimeType': 'video/VP8'},
);

List<StatsEntry> _report(num bytes, num at) => [
      _codec,
      _outbound('f', 1280, 720, bytes, at),
      _outbound('q', 640, 360, bytes ~/ 4, at),
      const StatsEntry(
        type: 'candidate-pair',
        id: 'pair',
        values: {
          'nominated': true,
          'currentRoundTripTime': 0.042,
          'availableOutgoingBitrate': 3000000,
          'localCandidateId': 'lc',
          'remoteCandidateId': 'rc',
        },
      ),
      const StatsEntry(
        type: 'local-candidate',
        id: 'lc',
        values: {'candidateType': 'relay', 'protocol': 'tcp'},
      ),
      const StatsEntry(
        type: 'remote-candidate',
        id: 'rc',
        values: {'candidateType': 'host'},
      ),
    ];

VideoStatsSample _parse(List<StatsEntry> entries,
        {VideoStatsSample? previous}) =>
    parseVideoStats(
      entries,
      identity: 'u1',
      name: 'Ada',
      source: CallStatsSource.camera,
      local: true,
      previous: previous,
    );

VideoStatsSample _parseIn(StatsEntry entry, {VideoStatsSample? previous}) =>
    parseVideoStats(
      [entry],
      identity: 'u2',
      name: 'Riley',
      source: CallStatsSource.screenShare,
      local: false,
      previous: previous,
    );

rtc.StatsReport _inbound(num bytes, double timestamp) => rtc.StatsReport('in-1',
    'inbound-rtp', timestamp, {'kind': 'video', 'bytesReceived': bytes});

void main() {
  group('StatsEntry.fromReport', () {
    // Native plugins stamp reports in microseconds; before this a 2 Mbps
    // share read as 0.00 Mbps.
    test('reads a native microsecond stamp so the bitrate is real', () {
      final first = _parseIn(StatsEntry.fromReport(_inbound(0, 10e6)));
      final second = _parseIn(
        StatsEntry.fromReport(_inbound(500000, 12e6)),
        previous: first,
      );
      // 500,000 bytes over 2 s is 2 Mbps.
      expect(second.streams.single.bitrateBps, closeTo(2e6, 1));
    });

    test('reads a browser millisecond stamp as it is', () {
      final entry = StatsEntry.fromReport(_inbound(0, 12000), web: true);
      expect(entry.timestampMs, 12000);
    });
  });

  group('parseVideoStats', () {
    test('reads each simulcast layer, smallest first', () {
      final sample = _parse(_report(1000000, 10000));
      expect(sample.streams.map((s) => s.rid), ['q', 'f']);
      final full = sample.streams.last;
      expect(full.width, 1280);
      expect(full.height, 720);
      expect(full.fps, 29.5);
      expect(full.targetBitrateBps, 1700000);
      expect(full.codec, 'VP8');
      expect(full.implementation, 'libvpx');
      expect(full.limitationReason, 'bandwidth');
      expect(full.limitationResolutionChanges, 2);
      expect(full.keyFrames, 4);
      expect(full.active, isTrue);
    });

    test('has no bitrate on the first sample', () {
      expect(_parse(_report(1000000, 10000)).streams.last.bitrateBps, isNull);
    });

    test('measures bitrate from the byte counter against the last sample', () {
      final first = _parse(_report(1000000, 10000));
      final second = _parse(_report(1625000, 15000), previous: first);
      // 625,000 bytes over 5 s is 1 Mbps.
      expect(second.streams.last.bitrateBps, closeTo(1000000, 1));
    });

    test('ignores a counter that went backwards', () {
      final first = _parse(_report(1000000, 10000));
      final second = _parse(_report(500, 15000), previous: first);
      expect(second.streams.last.bitrateBps, isNull);
    });

    test('names the network path', () {
      final transport = _parse(_report(1, 1)).transport!;
      expect(transport.rttMs, closeTo(42, 0.001));
      expect(transport.availableOutgoingBps, 3000000);
      expect(transport.localType, 'relay');
      expect(transport.protocol, 'tcp');
      expect(transport.relayed, isTrue);
    });

    test('reads the receiving side', () {
      final sample = parseVideoStats(
        const [
          StatsEntry(
            type: 'inbound-rtp',
            id: 'in-1',
            values: {
              'kind': 'video',
              'frameWidth': 640,
              'frameHeight': 360,
              'framesPerSecond': 24,
              'framesDropped': 7,
              'framesDecoded': 1234,
              'freezeCount': 2,
              'totalFreezesDuration': 1.5,
              'pauseCount': 1,
              'packetsLost': 12,
              'jitter': 0.01,
              'jitterBufferDelay': 4.0,
              'jitterBufferEmittedCount': 100,
              'decoderImplementation': 'ExternalDecoder',
              'keyFramesDecoded': 3,
              'pliCount': 1,
              'nackCount': 5,
            },
          ),
        ],
        identity: 'u2',
        name: 'Bo',
        source: CallStatsSource.screenShare,
        local: false,
      );
      final s = sample.streams.single;
      expect(s.framesDropped, 7);
      expect(s.framesDecoded, 1234);
      expect(s.freezeCount, 2);
      expect(s.freezeSeconds, 1.5);
      expect(s.pauseCount, 1);
      expect(s.packetsLost, 12);
      expect(s.jitterMs, closeTo(10, 0.001));
      expect(s.jitterBufferMs, closeTo(40, 0.001));
      expect(s.implementation, 'ExternalDecoder');
      expect(s.keyFrames, 3);
      expect(s.nackCount, 5);
      expect(sample.key, 'in/u2/screenShare');
    });

    test('skips audio streams and an empty report', () {
      expect(
        _parse(const [
          StatsEntry(type: 'outbound-rtp', id: 'a', values: {'kind': 'audio'}),
        ]).streams,
        isEmpty,
      );
      expect(_parse(const []).transport, isNull);
    });

    test('writes one console line per sample', () {
      final line = statsLogLine(_parse(_report(1000000, 10000)));
      expect(line, startsWith('[call-stats] out camera u1'));
      expect(line, contains('1280x720@30'));
      expect(line, contains('limit=bandwidth'));
      expect(line, contains('rtt=42ms relay/tcp'));
    });
  });

  group('CallStatsSampler', () {
    CallStatsTarget target(bool local, List<String> fetched) => CallStatsTarget(
          identity: local ? 'me' : 'them',
          name: 'n',
          source: CallStatsSource.camera,
          local: local,
          fetch: () async {
            fetched.add(local ? 'local' : 'remote');
            return _report(1000, 1000);
          },
        );

    test('does nothing until something listens', () {
      fakeAsync((async) {
        final fetched = <String>[];
        final sampler = CallStatsSampler(
          targets: () => [target(false, fetched)],
        );
        async.elapse(const Duration(seconds: 30));
        expect(fetched, isEmpty);
        expect(sampler.running, isFalse);
        unawaited(sampler.dispose());
      });
    });

    test('samples remote tracks every 2 s and local ones every 5 s', () {
      fakeAsync((async) {
        final fetched = <String>[];
        final lines = <String>[];
        final sampler = CallStatsSampler(
          targets: () => [target(false, fetched), target(true, fetched)],
          log: lines.add,
        );
        final sub = sampler.snapshots.listen((_) {});
        async.elapse(const Duration(seconds: 10, milliseconds: 100));
        expect(fetched.where((f) => f == 'remote').length, 6);
        expect(fetched.where((f) => f == 'local').length, 3);
        expect(lines, hasLength(9));
        expect(sampler.latest.map((s) => s.identity),
            unorderedEquals(['me', 'them']));
        unawaited(sub.cancel());
        unawaited(sampler.dispose());
      });
    });

    test('stops when the last listener leaves', () {
      fakeAsync((async) {
        final fetched = <String>[];
        final sampler = CallStatsSampler(
          targets: () => [target(false, fetched)],
        );
        final sub = sampler.snapshots.listen((_) {});
        async.elapse(const Duration(seconds: 3));
        unawaited(sub.cancel());
        async.flushMicrotasks();
        final seen = fetched.length;
        async.elapse(const Duration(seconds: 30));
        expect(fetched, hasLength(seen));
        expect(sampler.running, isFalse);
        expect(sampler.latest, isEmpty);
        unawaited(sampler.dispose());
      });
    });

    test('keeps sampling for the console while logging is on', () {
      fakeAsync((async) {
        final fetched = <String>[];
        final lines = <String>[];
        final sampler = CallStatsSampler(
          targets: () => [target(false, fetched)],
          log: lines.add,
        )..setLogging(true);
        async.elapse(const Duration(seconds: 4, milliseconds: 100));
        expect(lines, hasLength(3));
        sampler.setLogging(false);
        async.elapse(const Duration(seconds: 10));
        expect(lines, hasLength(3));
        unawaited(sampler.dispose());
      });
    });

    test('a failing fetch is skipped, not thrown', () {
      fakeAsync((async) {
        final sampler = CallStatsSampler(
          targets: () => [
            CallStatsTarget(
              identity: 'x',
              name: 'x',
              source: CallStatsSource.camera,
              local: false,
              fetch: () async => throw StateError('gone'),
            ),
          ],
        );
        final sub = sampler.snapshots.listen((_) {});
        async.elapse(const Duration(seconds: 5));
        expect(sampler.latest, isEmpty);
        unawaited(sub.cancel());
        unawaited(sampler.dispose());
      });
    });
  });
}
