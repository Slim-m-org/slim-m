// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A LiveKit room whose web peer connections mirror the start bitrate hint onto answers.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:livekit_client/livekit_client.dart' as lk;
// ignore: implementation_imports
import 'package:livekit_client/src/core/engine.dart' as lk_engine;

import 'start_bitrate_peer_connection.dart';

/// Native libwebrtc already seeds its estimator from the offer's hint, so only the browser needs the mirror.
lk.Room buildRoomWithStartBitrate(lk.RoomOptions roomOptions) => kIsWeb
    ? lk.Room(
        roomOptions: roomOptions,
        engine: lk_engine.Engine(
          connectOptions: const lk.ConnectOptions(),
          roomOptions: roomOptions,
          peerConnectionCreate: createStartBitratePeerConnection,
        ),
      )
    : lk.Room(roomOptions: roomOptions);
