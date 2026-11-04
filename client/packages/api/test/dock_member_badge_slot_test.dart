// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An installed module says whether it declares a `member.badge` or `profile.section` slot.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, dynamic> _installed([Map<String, dynamic> extra = const {}]) => {
      'id': 'xp',
      'name': 'xp',
      'version': '1.0.0',
      'artifact_sha256': 'a' * 64,
      'approved_capabilities': <String>[],
      'extension_points': <Object>[],
      'enabled': true,
      'installed_at': 1,
      ...extra,
    };

void main() {
  test('a member.badge slot is detected among the declared slots', () {
    final m = InstalledDockModule.fromJson(
      _installed({
        'slots': [
          {'kind': 'profile.section', 'name': 'level'},
          {'kind': 'member.badge', 'name': 'level'},
        ],
      }),
    );
    expect(m.declaresMemberBadge, isTrue);
    expect(m.declaresProfileSection, isTrue);
  });

  test('a module with other slots or none declares no member badge', () {
    final profileOnly = InstalledDockModule.fromJson(
      _installed({
        'slots': [
          {'kind': 'profile.section', 'name': 'level'},
        ],
      }),
    );
    expect(profileOnly.declaresMemberBadge, isFalse);
    expect(profileOnly.declaresProfileSection, isTrue);
    final none = InstalledDockModule.fromJson(_installed());
    expect(none.declaresMemberBadge, isFalse);
    expect(none.declaresProfileSection, isFalse);
  });
}
