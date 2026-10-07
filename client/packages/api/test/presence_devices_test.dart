// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The kinds of client a member is connected from: read off a frame and a
/// batch lookup, with anything the client does not know kept off "mobile".
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('presence.changed carries the connected device kinds', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'presence.changed',
        'user_id': 'u1',
        'status': 'online',
        'devices': ['mobile', 'desktop'],
      }),
    );
    expect((event as PresenceChanged).devices, {
      PresenceDevice.mobile,
      PresenceDevice.desktop,
    });
  });

  test('a frame without devices reads as none', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'presence.changed',
        'user_id': 'u1',
        'status': 'offline',
      }),
    );
    expect((event as PresenceChanged).devices, isEmpty);
  });

  test('a batch lookup carries devices, and an unknown kind is not mobile', () {
    final status = PresenceStatus.fromJson({
      'user_id': 'u1',
      'status': 'online',
      'devices': ['mobile', 'tablet'],
    });
    expect(status.devices, {PresenceDevice.mobile, PresenceDevice.unknown});
  });
}
