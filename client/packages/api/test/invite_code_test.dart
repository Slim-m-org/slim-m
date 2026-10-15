// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The invite a member registered through, which the server sends only to a
/// caller who can manage roles (issue 1774).
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('a member profile carries its invite code when sent', () {
    final profile = UserProfile.fromJson({
      'id': 'u1',
      'username': 'ada',
      'display_name': 'Ada',
      'created_at': 0,
      'invite_code': 'K7Q2',
    });
    expect(profile.inviteCode, 'K7Q2');
    expect(
      profile == UserProfile.fromJson({
        'id': 'u1',
        'username': 'ada',
        'display_name': 'Ada',
        'created_at': 0,
      }),
      isFalse,
      reason: 'a code arriving later must count as a change',
    );
  });

  test('a removal carries the code, and its absence reads as null', () {
    final withCode = SpaceRemoval.fromJson({
      'user_id': 'u1',
      'username': 'ada',
      'display_name': 'Ada',
      'removed_at': 1,
      'invite_code': 'K7Q2',
    });
    final without = SpaceRemoval.fromJson({
      'user_id': 'u2',
      'username': 'bob',
      'display_name': 'Bob',
      'removed_at': 1,
    });
    expect(withCode.inviteCode, 'K7Q2');
    expect(without.inviteCode, isNull);
  });
}
