// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The LiveKit room a call runs in: web peer connections mirror the start bitrate hint onto answers, and shared audio is declared stereo.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'start_bitrate_peer_connection.dart';
import 'stereo_share_engine.dart';

/// Native libwebrtc already seeds its estimator from the offer's hint, so only the browser needs the mirror.
lk.Room buildRoomWithStartBitrate(lk.RoomOptions roomOptions) => lk.Room(
      roomOptions: roomOptions,
      engine: StereoShareEngine(
        roomOptions: roomOptions,
        peerConnectionCreate: kIsWeb ? createStartBitratePeerConnection : null,
      ),
    );
