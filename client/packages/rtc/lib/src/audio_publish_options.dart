// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `AudioPublishOptions` the microphone is published with.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

/// Room-wide default, which the microphone publish picks up.
///
/// `red: false` turns redundant audio ON: livekit_client 2.13.1 passes the
/// field to the server as `disableRed`, so its default `true` disables it.
/// Under 5% loss RED cut dropouts from 11 to 0, and DTX off removed the
/// clipped burst on gliding tones (docs/research/voice-bursts.md).
lk.AudioPublishOptions microphonePublishOptions() =>
    const lk.AudioPublishOptions(red: false, dtx: false);
