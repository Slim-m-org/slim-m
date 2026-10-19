// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mapping LiveKit's own disconnect reason onto [VoiceDisconnect], split out
/// of `voice_session.dart` to make room there under this repo's file budget.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'voice_models.dart';

/// [reason] is never [lk.DisconnectReason.clientInitiated] here: that one
/// means `leave()` asked for it, and the caller checks for it separately
/// before ever reaching this mapping.
VoiceDisconnect mapDisconnectReason(lk.DisconnectReason? reason) =>
    switch (reason) {
      lk.DisconnectReason.duplicateIdentity =>
        VoiceDisconnect.replacedByOtherDevice,
      lk.DisconnectReason.participantRemoved ||
      lk.DisconnectReason.roomDeleted ||
      lk.DisconnectReason.roomClosed ||
      lk.DisconnectReason.serverShutdown =>
        VoiceDisconnect.removed,
      lk.DisconnectReason.signalingConnectionFailure ||
      lk.DisconnectReason.reconnectAttemptsExceeded ||
      lk.DisconnectReason.joinFailure ||
      lk.DisconnectReason.signalClose ||
      lk.DisconnectReason.connectionTimeout ||
      lk.DisconnectReason.mediaFailure ||
      lk.DisconnectReason.migration ||
      lk.DisconnectReason.disconnected =>
        VoiceDisconnect.connectionLost,
      _ => VoiceDisconnect.unknown,
    };
