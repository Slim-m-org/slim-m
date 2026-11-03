// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which screen share resolutions this machine can really send.
///
/// A share never goes above its source, so a tier taller than every screen
/// only promises a sharpness that cannot arrive.
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

/// The reason shown beside a tier the screens cannot reach.
const shareResolutionTooHighReason = 'Taller than your screen';

/// The tallest height a share can reach: the largest display, or the delivered size when capture came in smaller than the picked tier. Null when unknown.
int? maxShareHeight({
  required List<int> displayHeights,
  required ScreenShareResolution chosen,
  ({int width, int height})? captured,
}) {
  final display = displayHeights.isEmpty
      ? null
      : displayHeights.reduce((a, b) => a > b ? a : b);
  final smallerSource =
      captured != null &&
      captured.width < chosen.width &&
      captured.height < chosen.height;
  if (!smallerSource) return display;
  return display == null || captured.height < display
      ? captured.height
      : display;
}

/// The lowest tier is always offered, so a small screen still has a choice.
bool shareResolutionSupported(ScreenShareResolution tier, int? maxHeight) =>
    maxHeight == null ||
    tier.height <= maxHeight ||
    tier == ScreenShareResolution.values.first;

/// [chosen], or the tallest supported tier when the choice is out of reach.
ScreenShareResolution effectiveShareResolution(
  ScreenShareResolution chosen,
  int? maxHeight,
) {
  if (shareResolutionSupported(chosen, maxHeight)) return chosen;
  return ScreenShareResolution.values.lastWhere(
    (r) => shareResolutionSupported(r, maxHeight),
  );
}

/// Said under the resolution pick when some tiers are out of reach, so touch shows the reason hover shows.
String? shareResolutionNote(int? maxHeight) =>
    maxHeight != null &&
        ScreenShareResolution.values.any(
          (r) => !shareResolutionSupported(r, maxHeight),
        )
    ? 'Your screen is ${maxHeight}p, so taller sizes are off.'
    : null;

/// The heights of the screens the OS reports; a provider so a test can say what is plugged in.
final shareDisplayHeightsProvider = Provider<List<int>>(
  (ref) => [
    for (final d in PlatformDispatcher.instance.displays) d.size.height.round(),
  ],
);

/// What the screens and the live capture allow for [chosen].
int? currentMaxShareHeight(WidgetRef ref, ScreenShareResolution chosen) =>
    maxShareHeight(
      displayHeights: ref.watch(shareDisplayHeightsProvider),
      chosen: chosen,
      captured: localShareCapturedSize.value,
    );
