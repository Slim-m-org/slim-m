// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `owner.changed`: ownership passed to a member, who
/// now holds every permission.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('parses a well-formed owner.changed frame', () {
    final event = ServerEvent.parse(
      jsonEncode({'type': 'owner.changed', 'user_id': 'user-1'}),
    );
    expect(event, isA<OwnerChanged>());
    expect((event as OwnerChanged).userId, 'user-1');
  });

  test('a frame missing user_id is ignored, not thrown', () {
    final event = ServerEvent.parse(jsonEncode({'type': 'owner.changed'}));
    expect(event, isNull);
  });
}
