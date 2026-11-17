// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `GET /roles/{id}/preview` parses into categories and channels with their bits.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('a role preview reads back its nested categories and channel bits', () {
    final preview = RolePreview.fromJson(const {
      'role_id': 'r1',
      'permissions': 3,
      'categories': [
        {
          'id': 'c1',
          'name': 'gamers',
          'position': 0,
          'created_at': 1,
          'parent_id': null
        },
        {
          'id': 'c2',
          'name': 'cs2',
          'position': 0,
          'created_at': 1,
          'parent_id': 'c1'
        },
      ],
      'channels': [
        {
          'id': 'ch1',
          'name': 'cs-chat',
          'kind': 'voice',
          'position': 2,
          'category_id': 'c2',
          'permissions': 1,
          'restricted': true,
        },
      ],
    });
    expect(preview.roleId, 'r1');
    expect(preview.categories.last.parentId, 'c1');
    final channel = preview.channels.single;
    expect(channel.categoryId, 'c2');
    expect(channel.isVoice, isTrue);
    expect(channel.restricted, isTrue);
    expect(channel.permissions, 1);
  });
}
