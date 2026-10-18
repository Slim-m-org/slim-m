// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sharer is told once when the encoder holds their own share back.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

List<StatsEntry> _outgoing(String reason) => [
      StatsEntry(
        type: 'outbound-rtp',
        id: 'out-h',
        values: {
          'kind': 'video',
          'rid': 'h',
          'frameWidth': 960,
          'frameHeight': 540,
          'framesPerSecond': 12,
          'qualityLimitationReason': reason,
          'active': true,
        },
      ),
    ];

void main() {
  late String reason;
  late CallStatsSampler sampler;
  late ShareLimitMonitor monitor;

  void run(void Function(FakeAsync async) body) => fakeAsync((async) {
        reason = 'none';
        sampler = CallStatsSampler(
          targets: () => [
            CallStatsTarget(
              identity: 'me',
              name: 'Me',
              source: CallStatsSource.screenShare,
              local: true,
              fetch: () async => _outgoing(reason),
            ),
          ],
        );
        monitor = ShareLimitMonitor(sampler);
        monitor.sync(sharing: true);
        body(async);
        monitor.stop();
        sampler.dispose();
        async.flushTimers();
      });

  test('a limit seen once is not reported yet', () {
    run((async) {
      reason = 'cpu';
      async.elapse(const Duration(seconds: 6));
      expect(monitor.limit.value, isNull);
    });
  });

  test('the same limit twice in a row is reported', () {
    run((async) {
      reason = 'cpu';
      async.elapse(const Duration(seconds: 11));
      expect(monitor.limit.value, ShareLimit.cpu);
    });
  });

  test('a bandwidth limit is told apart from a cpu one', () {
    run((async) {
      reason = 'bandwidth';
      async.elapse(const Duration(seconds: 11));
      expect(monitor.limit.value, ShareLimit.bandwidth);
    });
  });

  test('a limit that flips between samples is not reported', () {
    run((async) {
      reason = 'cpu';
      async.elapse(const Duration(seconds: 6));
      reason = 'none';
      async.elapse(const Duration(seconds: 5));
      reason = 'cpu';
      async.elapse(const Duration(seconds: 5));
      expect(monitor.limit.value, isNull);
    });
  });

  test('a dismissed warning does not come back during the same share', () {
    run((async) {
      reason = 'cpu';
      async.elapse(const Duration(seconds: 11));
      monitor.dismiss();
      async.elapse(const Duration(seconds: 30));
      expect(monitor.limit.value, isNull);
    });
  });

  test('a new share can warn again', () {
    run((async) {
      reason = 'cpu';
      async.elapse(const Duration(seconds: 11));
      monitor.dismiss();
      monitor.sync(sharing: false);
      monitor.sync(sharing: true);
      async.elapse(const Duration(seconds: 11));
      expect(monitor.limit.value, ShareLimit.cpu);
    });
  });

  test('stopping the share clears the warning', () {
    run((async) {
      reason = 'cpu';
      async.elapse(const Duration(seconds: 11));
      monitor.sync(sharing: false);
      expect(monitor.limit.value, isNull);
    });
  });

  test('a paused layer is not blamed', () {
    final sample = parseVideoStats(
      [
        const StatsEntry(
          type: 'outbound-rtp',
          id: 'out-q',
          values: {
            'kind': 'video',
            'qualityLimitationReason': 'cpu',
            'active': false,
          },
        ),
      ],
      identity: 'me',
      name: 'Me',
      source: CallStatsSource.screenShare,
      local: true,
    );
    expect(shareLimitOf(sample), isNull);
  });
}
