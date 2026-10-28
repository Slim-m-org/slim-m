// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

VideoStatsSample _inbound(List<Map<String, Object?>> layers) => parseVideoStats(
      [
        for (var i = 0; i < layers.length; i++)
          StatsEntry(
            type: 'inbound-rtp',
            id: 'in-$i',
            values: {'kind': 'video', ...layers[i]},
          ),
      ],
      identity: 'u2',
      name: 'Riley',
      source: CallStatsSource.screenShare,
      local: false,
    );

void main() {
  group('streamQualityLabel', () {
    test('reads height and rounded fps', () {
      final s = _inbound([
        {'frameWidth': 1920, 'frameHeight': 1080, 'framesPerSecond': 59.6},
      ]);
      expect(streamQualityLabel(s), '1080p 60');
    });

    test('follows a simulcast layer switch on the next sample', () {
      final high = _inbound([
        {'frameWidth': 1280, 'frameHeight': 720, 'framesPerSecond': 30},
      ]);
      final low = _inbound([
        {'frameWidth': 640, 'frameHeight': 360, 'framesPerSecond': 15},
      ]);
      expect(streamQualityLabel(high), '720p 30');
      expect(streamQualityLabel(low), '360p 15');
    });

    test('drops fps when it is missing or zero', () {
      final s = _inbound([
        {'frameWidth': 1280, 'frameHeight': 720},
      ]);
      expect(streamQualityLabel(s), '720p');
      final stalled = _inbound([
        {'frameWidth': 1280, 'frameHeight': 720, 'framesPerSecond': 0},
      ]);
      expect(streamQualityLabel(stalled), '720p');
    });

    test('is null before a frame has arrived', () {
      expect(streamQualityLabel(null), isNull);
      expect(streamQualityLabel(_inbound([{}])), isNull);
    });

    test('keys a remote track the way the sampler does', () {
      final s = _inbound([
        {'frameHeight': 720},
      ]);
      expect(s.key, receivedStatsKey('u2', CallStatsSource.screenShare));
    });
  });
}
