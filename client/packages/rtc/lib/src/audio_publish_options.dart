// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `AudioPublishOptions` the microphone is published with.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

/// Room-wide default the microphone publish picks up.
/// `red: false` turns redundant audio ON (livekit_client 2.13.1 inverts it): under 5% loss RED cut dropouts from 11 to 0, and DTX off removed the clipped burst on gliding tones (docs/research/voice-bursts.md).
/// The 48 kbps bitrate is pinned so a livekit_client default change cannot move it; 24 and 32 kbps scored no better under loss (docs/research/mic-handling.md).
lk.AudioPublishOptions microphonePublishOptions() =>
    const lk.AudioPublishOptions(
      red: false,
      dtx: false,
      encoding: lk.AudioEncoding(maxBitrate: kMicrophoneBitrate),
    );

/// Bits per second, the livekit_client music preset the app already ran on.
const int kMicrophoneBitrate = 48000;
