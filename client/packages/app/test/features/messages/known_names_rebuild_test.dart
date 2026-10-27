// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A member refresh that returns the same names must not rebuild the message
/// bodies: the transcript used to build new username and role Sets each time.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';

import '../../channel_history_harness.dart';

final _tick = StateProvider<int>((ref) => 0);

api.UserProfile _member(String name, List<String> roles) => api.UserProfile(
  id: 'u-$name',
  username: name,
  displayName: name,
  createdAt: 0,
  roles: roles,
);

Future<int> _rebuildsOf<T extends Widget>(
  Future<void> Function() action,
) async {
  var count = 0;
  final previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    if (element.widget.runtimeType == T) count++;
  };
  try {
    await action();
  } finally {
    debugOnRebuildDirtyWidget = previous;
  }
  return count;
}

void main() {
  test('equal rosters give identical sets', () {
    final a = AsyncData([
      _member('Ann', ['Mods']),
    ]);
    final b = AsyncData([
      _member('ann', ['mods']),
    ]);

    expect(identical(knownUsernamesFrom(a), knownUsernamesFrom(b)), isTrue);
    expect(identical(knownRoleNamesFrom(a), knownRoleNamesFrom(b)), isTrue);
    expect(
      knownUsernamesFrom(AsyncData([_member('bo', [])])),
      isNot(knownUsernamesFrom(a)),
    );
  });

  testWidgets('a same-content member refresh rebuilds no message body', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: [for (var i = 1; i <= 6; i++) i],
      seededSeqs: [for (var i = 1; i <= 6; i++) i],
      overrides: [
        membersProvider.overrideWith((ref) async {
          ref.watch(_tick);
          return [
            _member('ann', ['mods']),
          ];
        }),
      ],
    );
    await flush(tester);

    final rebuilds = await _rebuildsOf<MessageBody>(() async {
      harness.container.read(_tick.notifier).state++;
      await flush(tester);
    });

    expect(rebuilds, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}
