// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A share resolution above every screen cannot be picked, and falls back to the tallest one that can.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/share_resolution_support.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  const p2160 = ScreenShareResolution.p2160;

  test('offers every tier when the screen is 4K or unknown', () {
    expect(shareResolutionSupported(p2160, 2160), isTrue);
    expect(shareResolutionSupported(p2160, null), isTrue);
  });

  test('disables tiers taller than the largest display', () {
    expect(shareResolutionSupported(p2160, 1440), isFalse);
    expect(shareResolutionSupported(ScreenShareResolution.p1440, 1440), isTrue);
  });

  test('keeps the lowest tier on a screen shorter than it', () {
    expect(shareResolutionSupported(ScreenShareResolution.p720, 600), isTrue);
  });

  test('falls back to the tallest supported tier', () {
    expect(effectiveShareResolution(p2160, 1080), ScreenShareResolution.p1080);
    expect(effectiveShareResolution(p2160, 1200), ScreenShareResolution.p1080);
    expect(effectiveShareResolution(p2160, 2160), p2160);
  });

  test('uses the largest of several displays', () {
    final max = maxShareHeight(
      displayHeights: [1080, 1440],
      chosen: ScreenShareResolution.p720,
    );
    expect(max, 1440);
  });

  test('a capture smaller than the picked tier caps the share', () {
    final max = maxShareHeight(
      displayHeights: [2160],
      chosen: ScreenShareResolution.p2160,
      captured: (width: 1920, height: 1080),
    );
    expect(max, 1080);
  });

  test('a capture scaled down to a low tier does not cap higher ones', () {
    final max = maxShareHeight(
      displayHeights: [1440],
      chosen: ScreenShareResolution.p720,
      captured: (width: 1280, height: 720),
    );
    expect(max, 1440);
  });

  test('notes the limit only when a tier is out of reach', () {
    expect(shareResolutionNote(1080), contains('1080p'));
    expect(shareResolutionNote(2160), isNull);
    expect(shareResolutionNote(null), isNull);
  });
}
