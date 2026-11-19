// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `voice.removed`: the server ended this account's call.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

VoiceRemoved? _parse(Map<String, Object?> frame) =>
    ServerEvent.parse(jsonEncode({'type': 'voice.removed', ...frame}))
        as VoiceRemoved?;

void main() {
  test('a call that moved to another device says so', () {
    final removed = _parse({'channel_id': 'a', 'reason': 'other_device'})!;
    expect(removed.channelId, 'a');
    expect(removed.reason, VoiceRemovalReason.otherDevice);
  });

  test('a reason newer than this client is still a removal', () {
    final removed = _parse({'channel_id': 'a', 'reason': 'kicked'})!;
    expect(removed.reason, VoiceRemovalReason.unknown);
  });

  test('a frame without its channel is ignored', () {
    expect(_parse({'reason': 'other_device'}), isNull);
  });
}
