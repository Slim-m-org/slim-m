// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Taking a failed publish's sender off the publisher connection.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Removes the sender carrying the track [cid] from [pc]; false when none does.
///
/// livekit adds the sender while it waits for the server's answer to the
/// publish request. When that answer is lost the publish fails with the sender
/// still attached, and on desktop a stopped audio track keeps sending.
Future<bool> withdrawSender(rtc.RTCPeerConnection pc, String cid) async {
  var removed = false;
  for (final sender in await pc.getSenders()) {
    if (sender.track?.id != cid) continue;
    await pc.removeTrack(sender);
    removed = true;
  }
  return removed;
}
