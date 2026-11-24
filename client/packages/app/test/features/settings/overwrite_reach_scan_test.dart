// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Working out who the viewer outranks reads the member list a bounded number
/// of times, not once per member.
library;

import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_columns.dart';
import 'package:slimm_app/src/role_ladder.dart';

class _CountingList<T> extends ListBase<T> {
  _CountingList(this._items);

  final List<T> _items;
  int reads = 0;

  @override
  int get length => _items.length;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  T operator [](int index) {
    reads++;
    return _items[index];
  }

  @override
  void operator []=(int index, T value) => throw UnsupportedError('read only');
}

void main() {
  test('outrankedKeys scans the members a few times, not per member', () {
    const count = 400;
    final members = _CountingList([
      for (var i = 0; i < count; i++)
        api.UserProfile(
          id: 'u$i',
          username: 'user$i',
          displayName: 'User $i',
          createdAt: 0,
          isOwner: i == 7,
        ),
    ]);
    final reach = OverwriteReach(
      ladder: const RoleLadder(permissions: 0, topPosition: 3),
      selfId: 'u0',
      roles: const [],
      members: members,
    );

    final keys = reach.outrankedKeys;

    expect(keys, contains('member:u7'));
    expect(members.reads, lessThan(count * 5));
  });
}
