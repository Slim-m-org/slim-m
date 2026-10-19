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
}
