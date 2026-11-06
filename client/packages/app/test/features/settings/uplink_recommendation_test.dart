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

  test('a 100 Mbit/s uplink serves five 1080p60 viewers at 70 percent', () {
    expect(viewersServed(100, p1080x60), 5);
  });

  test(
    'the suggested ceiling is the tallest tier that serves four viewers',
    () {
      expect(suggestedCeiling(200), ScreenShareResolution.p2160);
      expect(suggestedCeiling(100), ScreenShareResolution.p1440);
      expect(suggestedCeiling(60), ScreenShareResolution.p1080);
      expect(suggestedCeiling(20), ScreenShareResolution.p720);
    },
  );

  test('a very slow uplink still suggests the lowest tier', () {
    expect(suggestedCeiling(1), ScreenShareResolution.p720);
    expect(viewersServed(1, p1080x60), 0);
  });

  test('rates and viewers read plainly', () {
    expect(formatMbit(99.6), '100 Mbit/s');
    expect(formatMbit(4.25), '4.3 Mbit/s');
    expect(formatViewers(1), 'about 1 viewer');
    expect(formatViewers(8), 'about 8 viewers');
  });
}
