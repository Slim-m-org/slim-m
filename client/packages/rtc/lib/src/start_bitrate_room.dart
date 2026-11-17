// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The LiveKit room a call runs in: web peer connections mirror the start bitrate hint onto answers, Windows ones open no TCP listener when they need none, and shared audio is declared stereo.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'call_peer_configuration.dart';
import 'start_bitrate_peer_connection.dart';
import 'call_engine.dart';

/// Native libwebrtc already seeds its estimator from the offer's hint, so only the browser needs the mirror.
/// Windows peers drop TCP candidates when a TCP relay is offered (see `callPeerConfiguration`).
lk.Room buildRoomWithStartBitrate(lk.RoomOptions roomOptions) => lk.Room(
      roomOptions: roomOptions,
      engine: CallEngine(
        roomOptions: roomOptions,
        peerConnectionCreate: callPeerFactory(),
      ),
    );

/// The shape of LiveKit's peer connection factory, which it does not export.
typedef CallPeerFactory = Future<rtc.RTCPeerConnection> Function(
  Map<String, dynamic> configuration, [
  Map<String, dynamic> constraints,
]);

/// The peer connection factory a call's engine uses on this platform, or null for LiveKit's own.
CallPeerFactory? callPeerFactory({bool? web, bool? windows}) {
  if (web ?? kIsWeb) return createStartBitratePeerConnection;
  if (windows ?? lk.lkPlatformIs(lk.PlatformType.windows)) {
    return createCallPeerConnection;
  }
  return null;
}
