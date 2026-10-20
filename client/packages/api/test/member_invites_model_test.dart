// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('members_can_invite reads false when an older server omits it', () {
    final settings = SpaceSettings.fromJson({'join_policy': 'invite'});
    expect(settings.membersCanInvite, isFalse);
    final on = SpaceSettings.fromJson({
      'join_policy': 'invite',
      'members_can_invite': true,
    });
    expect(on.membersCanInvite, isTrue);
  });

  test('an invite carries who made it', () {
    final invite = Invite.fromJson({
      'code': 'abc',
      'uses': 0,
      'created_at': 1,
      'revoked': false,
      'usable': true,
      'created_by_name': 'Nia',
    });
    expect(invite.createdByName, 'Nia');
  });
}
