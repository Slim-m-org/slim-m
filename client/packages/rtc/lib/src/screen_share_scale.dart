// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Scaling a desktop share's encodings down to the layout it was published with.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Multiplies each encoding's scale by [factor], so the top layer matches the declared size and every lower layer keeps its ratio to it.
void scaleEncodings(List<rtc.RTCRtpEncoding> encodings, double factor) {
  for (final e in encodings) {
    e.scaleResolutionDownBy = (e.scaleResolutionDownBy ?? 1) * factor;
  }
}

/// Applies [factor] to [track]'s sender once it is published; a factor of 1 leaves the sender alone.
Future<void> applyCaptureScale(lk.LocalVideoTrack track, double factor) async {
  final sender = track.sender;
  if (factor <= 1 || sender == null) return;
  final params = sender.parameters;
  final encodings = params.encodings;
  if (encodings == null || encodings.isEmpty) return;
  scaleEncodings(encodings, factor);
  try {
    final ok = await sender.setParameters(params);
    AppLog.info(
        LogTag.voice, 'Screen share capture scaled down by $factor: $ok');
  } catch (e) {
    AppLog.info(LogTag.voice, 'Screen share capture scale not applied: $e');
  }
}
