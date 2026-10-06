// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile card's composition rule: a section you have no rights or
/// context for is *absent*, never present-and-disabled. That is what keeps a
/// plain member's card to a couple of verbs instead of a wall of greyed
/// rows, and it is the rule most likely to erode as sections are added.
///
/// Moderate's own content (the roles checklist, timeout chips, reset code,
/// remove button) is `member_moderate_view_test.dart`'s concern; this file
/// only checks that the single "Moderate..." row appears exactly when at
/// least one of those rights is held.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/call_header_fixture.dart' show FakePresence;

const _other = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
  roles: ['mod'],
  roleIds: ['role-mod'],
);

/// An hour out, so the badge's own arithmetic has something real to render.
final _timedOut = api.UserProfile(
  id: _other.id,
  username: _other.username,
  displayName: _other.displayName,
  createdAt: 0,
  roles: _other.roles,
  roleIds: _other.roleIds,
  timedOutUntil: DateTime.now()
      .add(const Duration(hours: 1))
      .millisecondsSinceEpoch,
);

Widget _harness(
  Widget child, {
  int permissions = 0,
  List<api.UserProfile> members = const [],
  Map<String, api.PresenceState> presence = const {
    'user-maya': api.PresenceState.online,
  },
}) => ProviderScope(
  key: UniqueKey(),
  overrides: [
    presenceControllerProvider.overrideWith(
      (ref) => FakePresence(ref, presence),
    ),
    myPermissionsProvider.overrideWithValue(permissions),
    membersProvider.overrideWith((ref) async => members),
    rolesProvider.overrideWith((ref) async => const <api.Role>[]),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    // A real popover scrolls; this harness needs the same allowance.
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

Widget _body(api.UserProfile profile) =>
    MemberProfileBody(profile: profile, compact: false, onDone: () {});

void main() {
  testWidgets('a plain member gets the social verbs and block, nothing else', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_body(_other)));
    await tester.pump();

    expect(find.text('maya'), findsOneWidget);
    expect(find.text('@maya'), findsOneWidget);
    expect(find.text('online'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    expect(find.text('Add a private note'), findsOneWidget);

    // No call in progress, so nothing about hearing them.
    expect(
      find.text('Mute for me'),
      findsNothing,
      reason: 'the call section belongs to a shared call, not to a person',
    );
    // No rights, so no way into Moderate at all.
    expect(find.text('Moderate...'), findsNothing);
  });

  testWidgets('a renamed member still shows the account name', (tester) async {
    const renamed = api.UserProfile(
      id: 'user-maya',
      username: 'maya',
      displayName: 'House DJ',
      nickname: 'House DJ',
      accountDisplayName: 'Maya',
      createdAt: 0,
    );
    await tester.pumpWidget(_harness(_body(renamed)));
    await tester.pump();

    expect(find.text('House DJ'), findsOneWidget);
    expect(find.text('@maya · account name Maya'), findsOneWidget);
  });

  testWidgets('the profile composes before any action row', (tester) async {
    await tester.pumpWidget(_harness(_body(_other)));
    await tester.pump();

    final name = tester.getTopLeft(find.text('maya'));
    final handle = tester.getTopLeft(find.text('@maya'));
    final message = tester.getTopLeft(find.text('Message'));
    expect(handle.dy, greaterThan(name.dy));
    expect(message.dy, greaterThan(handle.dy));
  });

  testWidgets('roles show as chips, beside the join date, for everyone', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_body(_other)));
    await tester.pump();

    expect(find.text('mod'), findsOneWidget);
    expect(find.textContaining('joined'), findsOneWidget);
  });

  testWidgets('a Moderate row opens only with a moderation right', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_body(_other)));
    await tester.pump();
    expect(find.text('Moderate...'), findsNothing);

    for (final perm in [
      Perm.kickMembers,
      Perm.banMembers,
      Perm.manageRoles,
      Perm.administrator,
    ]) {
      await tester.pumpWidget(_harness(_body(_other), permissions: perm));
      await tester.pump();
      expect(find.text('Moderate...'), findsOneWidget, reason: '$perm');
    }
  });

  testWidgets('tapping Moderate pushes its own view, with a way back', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(_body(_other), permissions: Perm.banMembers),
    );
    await tester.pump();

    await tester.tap(find.text('Moderate...'));
    await tester.pumpAndSettle();

    expect(find.text('Moderate maya'), findsOneWidget);
    expect(
      find.text('maya'),
      findsNothing,
      reason: 'the profile view is replaced, not stacked underneath',
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Moderate maya'), findsNothing);
    expect(find.text('maya'), findsOneWidget);
  });

  testWidgets('Esc steps back out of Moderate before closing the card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(_body(_other), permissions: Perm.banMembers),
    );
    await tester.pump();

    await tester.tap(find.text('Moderate...'));
    await tester.pumpAndSettle();
    expect(find.text('Moderate maya'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.text('Moderate maya'),
      findsNothing,
      reason: 'the first Esc returns to the profile, not the caller',
    );
    expect(find.text('maya'), findsOneWidget);
  });

  testWidgets('presence is a word beside its dot, never the dot alone', (
    tester,
  ) async {
    for (final (state, word) in const [
      (api.PresenceState.online, 'online'),
      (api.PresenceState.away, 'away'),
      (api.PresenceState.dnd, 'do not disturb'),
      (api.PresenceState.offline, 'offline'),
    ]) {
      await tester.pumpWidget(
        _harness(_body(_other), presence: {_other.id: state}),
      );
      await tester.pump();
      expect(find.text(word), findsOneWidget, reason: '$state');
      expect(find.byType(AppStatusDot), findsWidgets, reason: '$state');
    }
  });

  testWidgets('nobody reported yet reads as no word and no dot', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_body(_other), presence: const {}));
    await tester.pump();
    for (final word in ['online', 'away', 'offline', 'unknown']) {
      expect(find.text(word), findsNothing);
    }
    expect(find.byType(AppStatusDot), findsNothing);
  });

  testWidgets('the compact presentation carries the same rows', (tester) async {
    await tester.pumpWidget(
      _harness(
        MemberProfileBody(profile: _other, compact: true, onDone: () {}),
      ),
    );
    await tester.pump();

    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
  });

  group('the timed-out badge', () {
    testWidgets(
      'names exactly what is restricted, for anyone who can see them',
      (tester) async {
        await tester.pumpWidget(_harness(_body(_timedOut)));
        await tester.pump();

        expect(find.textContaining('Timed out'), findsOneWidget);
        expect(
          find.text(
            'Can read messages and view the canvas; '
            "can't draw, send messages, or join voice.",
          ),
          findsOneWidget,
        );
        expect(
          find.text('Lift'),
          findsNothing,
          reason: 'a member without the right sees the badge but no verb',
        );
      },
    );

    testWidgets('offers Lift to somebody who can actually lift it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(_body(_timedOut), permissions: Perm.kickMembers),
      );
      await tester.pump();
      expect(find.text('Lift'), findsOneWidget);
    });

    testWidgets('is absent for a member who is not timed out', (tester) async {
      await tester.pumpWidget(
        _harness(_body(_other), permissions: Perm.kickMembers),
      );
      await tester.pump();
      expect(find.textContaining('Timed out'), findsNothing);
    });
  });
}
