// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/src/voice_disconnect_reason.dart';
import 'package:slimm_rtc/src/voice_models.dart';

void main() {
  test('a room closed by the server is a removal, not an unknown end', () {
    expect(
      mapDisconnectReason(lk.DisconnectReason.roomClosed),
      VoiceDisconnect.removed,
    );
  });

  test('drops livekit names since 2.11 are retryable losses', () {
    for (final reason in [
      lk.DisconnectReason.signalClose,
      lk.DisconnectReason.connectionTimeout,
      lk.DisconnectReason.mediaFailure,
      lk.DisconnectReason.migration,
    ]) {
      expect(mapDisconnectReason(reason), VoiceDisconnect.connectionLost,
          reason: '$reason');
    }
  });

  test('a duplicate identity still means another device took the call', () {
    expect(
      mapDisconnectReason(lk.DisconnectReason.duplicateIdentity),
      VoiceDisconnect.replacedByOtherDevice,
    );
  });

  test('the server stopping or losing the session is a retryable loss', () {
    for (final reason in [
      lk.DisconnectReason.serverShutdown,
      lk.DisconnectReason.stateMismatch,
    ]) {
      expect(mapDisconnectReason(reason), VoiceDisconnect.connectionLost,
          reason: '$reason');
    }
  });

  group('every reason livekit names', () {
    const expected = {
      lk.DisconnectReason.unknown: VoiceDisconnect.unknown,
      lk.DisconnectReason.clientInitiated: VoiceDisconnect.unknown,
      lk.DisconnectReason.duplicateIdentity:
          VoiceDisconnect.replacedByOtherDevice,
      lk.DisconnectReason.serverShutdown: VoiceDisconnect.connectionLost,
      lk.DisconnectReason.participantRemoved: VoiceDisconnect.removed,
      lk.DisconnectReason.roomDeleted: VoiceDisconnect.removed,
      lk.DisconnectReason.stateMismatch: VoiceDisconnect.connectionLost,
      lk.DisconnectReason.joinFailure: VoiceDisconnect.connectionLost,
      lk.DisconnectReason.disconnected: VoiceDisconnect.connectionLost,
      lk.DisconnectReason.signalingConnectionFailure:
          VoiceDisconnect.connectionLost,
      lk.DisconnectReason.reconnectAttemptsExceeded:
          VoiceDisconnect.connectionLost,
      lk.DisconnectReason.migration: VoiceDisconnect.connectionLost,
      lk.DisconnectReason.signalClose: VoiceDisconnect.connectionLost,
      lk.DisconnectReason.roomClosed: VoiceDisconnect.removed,
      lk.DisconnectReason.userUnavailable: VoiceDisconnect.unknown,
      lk.DisconnectReason.userRejected: VoiceDisconnect.unknown,
      lk.DisconnectReason.sipTrunkFailure: VoiceDisconnect.unknown,
      lk.DisconnectReason.connectionTimeout: VoiceDisconnect.connectionLost,
      lk.DisconnectReason.mediaFailure: VoiceDisconnect.connectionLost,
      lk.DisconnectReason.agentError: VoiceDisconnect.unknown,
    };

    test('has a row, so a reason added by an upgrade is decided here', () {
      expect(expected.keys.toSet(), lk.DisconnectReason.values.toSet());
    });

    for (final entry in expected.entries) {
      test('${entry.key.name} ends the call as ${entry.value.name}', () {
        expect(mapDisconnectReason(entry.key), entry.value);
      });
    }

    test('no reason leaves the call without an answer', () {
      expect(mapDisconnectReason(null), VoiceDisconnect.unknown);
    });
  });
}
