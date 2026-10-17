// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this platform can publish audio with a shared screen. The
/// per-platform answer, traced through livekit_client and flutter_webrtc, is
/// in docs/research/video-handling.md.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:livekit_client/livekit_client.dart' as lk;

/// Whether this platform can add an audio track to a screen share. Linux is
/// true though it depends on a build flag, since a build without it just
/// shares video. [platform] lets a test pick the platform, because CI runs
/// on Linux, which is itself a true answer.
bool supportsScreenShareAudio({@visibleForTesting lk.PlatformType? platform}) {
  final onPlatform = platform ?? lk.lkPlatform();
  return onPlatform == lk.PlatformType.web ||
      onPlatform == lk.PlatformType.linux;
}
