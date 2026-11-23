// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Outside a browser the fork's native plugin runs the capture chain.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

bool get webCaptureChainAvailable => false;

Future<Object?> invokeWebCaptureChain(String method, [Object? args]) =>
    throw UnsupportedError('$method needs a browser');

lk.TrackProcessor<lk.AudioProcessorOptions>? webCaptureProcessor() => null;

Future<rtc.MediaStreamTrack> attachWebCaptureChain(
  rtc.MediaStreamTrack track,
) async =>
    track;

Future<void> detachWebCaptureChain(rtc.MediaStreamTrack processed) async {}
