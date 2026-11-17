// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mention chip finds its member by key, so a roster change walks the
/// roster once however many mentions are on screen.
library;

import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/mention_names.dart';
import 'package:slimm_app/src/providers/live_events.dart';

class _CountingRoster extends ListBase<api.UserProfile> {
  _CountingRoster(this._members);

  final List<api.UserProfile> _members;
  int walks = 0;

  @override
  int get length => _members.length;

  @override
  set length(int value) => _members.length = value;

  @override
  api.UserProfile operator [](int index) => _members[index];

  @override
  void operator []=(int index, api.UserProfile value) =>
      _members[index] = value;

  @override
  Iterator<api.UserProfile> get iterator {
    walks++;
    return _members.iterator;
  }
}

api.UserProfile _member(String id, String username) =>
    api.UserProfile(id: id, username: username, displayName: '', createdAt: 0);

void main() {
  test('many mentions walk the roster once between them', () async {
    final roster = _CountingRoster([
      for (var i = 0; i < 20; i++) _member('u$i', 'User$i'),
    ]);
    final container = ProviderContainer(
      overrides: [
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        membersProvider.overrideWith((ref) async => roster),
      ],
    );
    addTearDown(container.dispose);
    container.listen(membersProvider, (_, _) {});
    await container.read(membersProvider.future);

    final found = [
      for (var i = 0; i < 10; i++)
        container.listen(mentionProfileProvider('user$i'), (_, _) {}).read(),
    ];

    expect(found.map((m) => m?.id), [for (var i = 0; i < 10; i++) 'u$i']);
    expect(roster.walks, 1);
  });
}
