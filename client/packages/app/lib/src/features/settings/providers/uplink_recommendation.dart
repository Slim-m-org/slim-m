// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turns a measured uplink into screen-share advice.
library;

import 'package:slimm_rtc/rtc.dart';

/// Share of the uplink counted as usable; the rest is left for call audio and overhead.
const uplinkUsableShare = 0.7;

/// The tiers listed, in the order shown.
const uplinkAdviceTiers = <ScreenShareQuality>[
  ScreenShareQuality(ScreenShareResolution.p720, ScreenShareFps.fps30),
  ScreenShareQuality(ScreenShareResolution.p1080, ScreenShareFps.fps30),
  ScreenShareQuality(ScreenShareResolution.p1080, ScreenShareFps.fps60),
  ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps30),
  ScreenShareQuality(ScreenShareResolution.p2160, ScreenShareFps.fps30),
];

/// How many viewer streams of [quality] the uplink carries; the host sends one copy per viewer.
int viewersServed(double mbitPerSecond, ScreenShareQuality quality) =>
    (mbitPerSecond * uplinkUsableShare * 1e6 / quality.maxBitrate).floor();

/// Viewers a typical call needs served at once, across every share.
const typicalCallViewers = 4;

/// The tallest resolution at 30 fps that serves [typicalCallViewers], never below 720p.
ScreenShareResolution suggestedCeiling(double mbitPerSecond) {
  var best = ScreenShareResolution.p720;
  for (final resolution in ScreenShareResolution.values) {
    final quality = ScreenShareQuality(resolution, ScreenShareFps.fps30);
    if (viewersServed(mbitPerSecond, quality) >= typicalCallViewers) {
      best = resolution;
    }
  }
  return best;
}

/// `99 Mbit/s`, or one decimal under 10.
String formatMbit(double mbitPerSecond) => mbitPerSecond >= 10
    ? '${mbitPerSecond.round()} Mbit/s'
    : '${mbitPerSecond.toStringAsFixed(1)} Mbit/s';

/// `about 8 viewers`.
String formatViewers(int viewers) =>
    'about $viewers ${viewers == 1 ? 'viewer' : 'viewers'}';
