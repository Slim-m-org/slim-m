// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A share never publishes above the screen it captures or the space ceiling.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

const _p2160 = ScreenShareQuality(
  ScreenShareResolution.p2160,
  ScreenShareFps.fps30,
);

void main() {
  test('a 1080p screen with the 2160p tier publishes 1080p at its bitrate', () {
    final fit = fitScreenShare(_p2160, sourceWidth: 1920, sourceHeight: 1080);
    expect(fit.quality.resolution, ScreenShareResolution.p1080);
    expect((fit.width, fit.height), (1920, 1080));
    expect(fit.quality.maxBitrate, 5000000);
  });

  test('a 4K screen keeps the 2160p tier', () {
    final fit = fitScreenShare(_p2160, sourceWidth: 3840, sourceHeight: 2160);
    expect(fit.quality, _p2160);
    expect((fit.width, fit.height), (3840, 2160));
  });

  test('the frame rate is kept when the size drops', () {
    final fit = fitScreenShare(
      const ScreenShareQuality(
          ScreenShareResolution.p1440, ScreenShareFps.fps60),
      sourceWidth: 1920,
      sourceHeight: 1080,
    );
    expect(fit.quality.fps, 60);
    expect(fit.quality.resolution, ScreenShareResolution.p1080);
  });

  test('the space ceiling wins over a larger source', () {
    final fit = fitScreenShare(
      _p2160,
      sourceWidth: 3840,
      sourceHeight: 2160,
      maxHeight: 1440,
    );
    expect(fit.quality.resolution, ScreenShareResolution.p1440);
  });

  test('a source between tiers rounds down to the tier below', () {
    final fit = fitScreenShare(_p2160, sourceWidth: 2560, sourceHeight: 1600);
    expect(fit.quality.resolution, ScreenShareResolution.p1440);
    expect((fit.width, fit.height), (2304, 1440));
    expect(fit.captureScale, closeTo(1600 / 1440, 1e-9));
  });

  test('a source below 720p publishes at its own size', () {
    final fit = fitScreenShare(_p2160, sourceWidth: 1366, sourceHeight: 600);
    expect(fit.quality.resolution, ScreenShareResolution.p720);
    expect((fit.width, fit.height), (1366, 600));
    expect(fit.captureScale, 1);
  });

  test('a smaller choice is not raised to the source', () {
    final fit = fitScreenShare(
      ScreenShareQuality.standard,
      sourceWidth: 3840,
      sourceHeight: 2160,
    );
    expect(fit.quality, ScreenShareQuality.standard);
  });

  test('a 4K screen on the 1080p tier scales the capture down by two', () {
    final fit = fitScreenShare(
      const ScreenShareQuality(
          ScreenShareResolution.p1080, ScreenShareFps.fps60),
      sourceWidth: 3840,
      sourceHeight: 2160,
    );
    expect((fit.width, fit.height), (1920, 1080));
    expect(fit.captureScale, 2);
  });

  test('an ultrawide keeps its aspect and scales by the height ratio', () {
    final fit = fitScreenShare(
      const ScreenShareQuality(
          ScreenShareResolution.p1080, ScreenShareFps.fps30),
      sourceWidth: 3440,
      sourceHeight: 1440,
    );
    expect((fit.width, fit.height), (2580, 1080));
    expect(fit.captureScale, closeTo(1440 / 1080, 1e-9));
  });

  test('a source at or under the tier is not scaled', () {
    final fit = fitScreenShare(_p2160, sourceWidth: 1920, sourceHeight: 1080);
    expect(fit.captureScale, 1);
  });

  group('when the first frame never arrives', () {
    test('the space ceiling still lowers the tier and its bitrate', () {
      final fit = fitMeasured(_p2160, null, maxHeight: 1080);
      expect(fit.quality.resolution, ScreenShareResolution.p1080);
      expect((fit.width, fit.height), (1920, 1080));
      expect(fit.quality.maxBitrate, 5000000);
    });

    test('the chosen tier stands when no ceiling is lower', () {
      final fit = fitMeasured(_p2160, null);
      expect(fit.quality, _p2160);
      expect((fit.width, fit.height), (3840, 2160));
    });

    test('a measured size still wins over the chosen tier', () {
      final fit = fitMeasured(_p2160, (width: 1366, height: 768));
      expect(fit.quality.resolution, ScreenShareResolution.p720);
      expect((fit.width, fit.height), (1280, 720));
    });
  });
}
