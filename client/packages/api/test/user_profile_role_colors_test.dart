// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `role_colors` parses positionally beside `roles`, and an older server
/// that sends none reads as no colours rather than failing the profile.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, dynamic> _json([Object? colours]) => {
      'id': 'user-1',
      'username': 'ada',
      'display_name': 'Ada',
      'created_at': 0,
      'roles': ['Admin', 'Regulars', 'Mods'],
      'role_ids': ['r-1', 'r-2', 'r-3'],
      if (colours != null) 'role_colors': colours,
    };

void main() {
  test('colours line up with roles, null where none was chosen', () {
    final profile = UserProfile.fromJson(_json([null, 6, 2]));
    expect(profile.roleColors, [null, 6, 2]);
  });

  test('an older server without the field reads as no colours', () {
    expect(UserProfile.fromJson(_json()).roleColors, isEmpty);
  });

  test('a malformed entry reads as no colour instead of throwing', () {
    final profile = UserProfile.fromJson(_json(['gold', 6, 1.5]));
    expect(profile.roleColors, [null, 6, null]);
  });
}
