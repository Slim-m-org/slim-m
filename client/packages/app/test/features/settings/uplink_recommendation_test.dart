// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The uplink advice: how many shares fit and which ceiling is suggested.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/uplink_recommendation.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  const p1080x60 = ScreenShareQuality(
    ScreenShareResolution.p1080,
    ScreenShareFps.fps60,
  );

  test('a 100 Mbit/s uplink fits eight 1080p60 shares at 70 percent', () {
    expect(sharesThatFit(100, p1080x60), 8);
  });

  test('the suggested ceiling is the tallest tier that fits two shares', () {
    expect(suggestedCeiling(100), ScreenShareResolution.p2160);
    expect(suggestedCeiling(20), ScreenShareResolution.p1080);
    expect(suggestedCeiling(8), ScreenShareResolution.p720);
  });

  test('a very slow uplink still suggests the lowest tier', () {
    expect(suggestedCeiling(1), ScreenShareResolution.p720);
    expect(sharesThatFit(1, p1080x60), 0);
  });

  test('rates and bitrates read as Mbit/s', () {
    expect(formatMbit(99.6), '100 Mbit/s');
    expect(formatMbit(4.25), '4.3 Mbit/s');
    expect(formatBitrate(8000000), '8 Mbit/s');
    expect(formatBitrate(7500000), '7.5 Mbit/s');
  });
}
