// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An `@mention` of a member inside a message opens that member's profile,
/// the same card a click on an author's name opens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/features/messages/widgets/transcript_selection.dart';

import '../../support/async_wait.dart';
import 'message_row_harness.dart';

const _welcomed = api.UserProfile(
  id: 'user-7',
  username: 'taka',
  displayName: 'Taka',
  createdAt: 0,
);

Widget _greeting() => MessageRow(
  message: message(
    authorId: 'greeter-bot',
    authorDisplayName: 'Greeter',
    content: 'Welcome @taka, glad you are here',
  ),
  grouped: false,
  showNewDivider: false,
  knownUsernames: const {'taka'},
  actions: noActions,
  editing: false,
  callbacks: MessageRowCallbacks(
    onRetry: noop,
    onDiscard: noop,
    onPickReaction: (_) {},
    onReactionTap: (_) {},
    onVote: (_) {},
    onSubmitEdit: (_) {},
    onCancelEdit: noop,
  ),
);

Future<void> _tapMention(WidgetTester tester, {bool selectable = false}) async {
  await tester.pumpWidget(
    harness(
      selectable ? TranscriptSelection(child: _greeting()) : _greeting(),
      overrides: [
        membersProvider.overrideWith((ref) async => [_welcomed]),
      ],
    ),
  );
  await pumpFrames(tester);
  expect(find.text('@Taka'), findsOneWidget);
  await tester.tap(find.text('@Taka'));
  await pumpFrames(tester, frames: 30);
}

void main() {
  testWidgets('clicking a mention opens the mentioned member\'s profile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _tapMention(tester);

    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Taka'), findsWidgets);
  });

  testWidgets('tapping a mention at phone width opens the profile too', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _tapMention(tester);

    expect(find.text('Message'), findsOneWidget);
  });

  testWidgets('a mention in the selectable desktop transcript still opens '
      'the profile on a tap', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _tapMention(tester, selectable: true);

    expect(find.text('Message'), findsOneWidget);
  });
}
