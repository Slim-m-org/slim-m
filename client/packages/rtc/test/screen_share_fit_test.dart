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
    expect((fit.width, fit.height), (2560, 1440));
  });

  test('a source below 720p publishes at its own size', () {
    final fit = fitScreenShare(_p2160, sourceWidth: 1366, sourceHeight: 600);
    expect(fit.quality.resolution, ScreenShareResolution.p720);
    expect((fit.width, fit.height), (1280, 600));
  });

  test('a smaller choice is not raised to the source', () {
    final fit = fitScreenShare(
      ScreenShareQuality.standard,
      sourceWidth: 3840,
      sourceHeight: 2160,
    );
    expect(fit.quality, ScreenShareQuality.standard);
  });
}
