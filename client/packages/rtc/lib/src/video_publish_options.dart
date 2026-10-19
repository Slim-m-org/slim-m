// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `VideoPublishOptions` each video source is published with.
///
/// Capture params only size the capture. LiveKit reads the encoder ceiling and
/// the degradation preference from publish options alone, and falls back to a
/// preset picked by width when they are missing.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'screen_share.dart';

/// A camera on a weak uplink should lose sharpness, not smoothness.
const cameraDegradationPreference = lk.DegradationPreference.maintainFramerate;

/// Quietly lowers size or rate together when the machine or the link cannot
/// keep up, instead of stuttering or asking the sharer to change a setting.
const screenShareDegradationPreference = lk.DegradationPreference.balanced;

/// Room-wide defaults, which a camera publish picks up.
lk.VideoPublishOptions cameraPublishOptions() => const lk.VideoPublishOptions(
      degradationPreference: cameraDegradationPreference,
    );

/// Carries [quality]'s bitrate and frame rate to the encoder.
lk.VideoPublishOptions screenSharePublishOptionsFor(
  ScreenShareQuality quality,
) =>
    lk.VideoPublishOptions(
      screenShareEncoding: lk.VideoEncoding(
        maxBitrate: quality.maxBitrate,
        maxFramerate: quality.fps,
      ),
      simulcast: true,
      degradationPreference: screenShareDegradationPreference,
    );
