// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screen share bitrate table, cell by cell.
///
/// The cells are the contract with the encoder, so each one is spelled out
/// rather than recomputed from a formula that would drift with the code.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

int _bitrate(ScreenShareResolution r, ScreenShareFps f) =>
    ScreenShareQuality(r, f).maxBitrate;

void main() {
  group('screen share bitrate table', () {
    test('is anchored on LiveKit 720p30 = 2 Mbps and 1080p30 = 5 Mbps', () {
      expect(
          _bitrate(ScreenShareResolution.p720, ScreenShareFps.fps30), 2000000);
      expect(
        _bitrate(ScreenShareResolution.p1080, ScreenShareFps.fps30),
        5000000,
      );
    });

    test('holds every cell', () {
      const expected = {
        '720p15': 1500000,
        '720p30': 2000000,
        '720p60': 3200000,
        '1080p15': 2500000,
        '1080p30': 5000000,
        '1080p60': 8000000,
        '1440p15': 4000000,
        '1440p30': 7500000,
        '1440p60': 12000000,
        '2160p15': 6000000,
        '2160p30': 10000000,
        '2160p60': 12000000,
      };
      expect({for (final q in ScreenShareQuality.all) q.id: q.maxBitrate},
          expected);
    });

    test('never exceeds the ceiling', () {
      for (final q in ScreenShareQuality.all) {
        expect(
            q.maxBitrate, lessThanOrEqualTo(ScreenShareQuality.bitrateCeiling));
      }
    });

    test('doubling the frame rate costs more, but less than double again', () {
      for (final r in ScreenShareResolution.values) {
        final at15 = _bitrate(r, ScreenShareFps.fps15);
        final at30 = _bitrate(r, ScreenShareFps.fps30);
        final at60 = _bitrate(r, ScreenShareFps.fps60);
        expect(at30, greaterThan(at15));
        expect(at60, greaterThanOrEqualTo(at30));
        expect(at60, lessThanOrEqualTo(at30 * 2));
      }
    });
  });
}
