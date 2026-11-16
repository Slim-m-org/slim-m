// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The identity block of a member card: someone with no display name of their
/// own shows their username once, presence is the dot on the avatar rather
/// than a word line, a typed status keeps its own line, and the join date
/// closes the block.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';
import 'package:slimm_app/src/features/members/providers/presence_view.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/call_header_fixture.dart' show FakePresence;

const _nov2026 = 1793750400000;

api.UserProfile _user(
  String displayName, {
  List<String> roles = const [],
  String? statusText,
}) => api.UserProfile(
  id: 'user-test',
  username: 'testuser123',
  displayName: displayName,
  createdAt: _nov2026,
  roles: roles,
  profileColor: 2,
  statusText: statusText,
);

Future<void> _pump(
  WidgetTester tester,
  api.UserProfile profile, {
  AppPresence presence = AppPresence.offline,
  List<Override> overrides = const [],
  bool compact = false,
}) async {
  tester.view.physicalSize = Size(compact ? 390 : 800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        membersProvider.overrideWith((ref) async => [profile]),
        if (overrides.isEmpty)
          presenceForProvider.overrideWith((ref, id) => presence),
        ...overrides,
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MemberProfileBody(
              profile: profile,
              compact: compact,
              profileOnly: true,
              onDone: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// The presence dots drawn on the card's avatar.
List<AppStatusDot> _avatarDots(WidgetTester tester) => tester
    .widgetList<AppStatusDot>(
      find.descendant(
        of: find.byKey(const Key('member-profile-avatar-slot')),
        matching: find.byWidgetPredicate((w) => w is AppStatusDot),
      ),
    )
    .toList();

const _selfSession = api.TokenPair(
  userId: 'user-test',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets('no display name of their own shows the username once', (
    tester,
  ) async {
    await _pump(tester, _user('testuser123'));

    expect(find.text('testuser123'), findsOneWidget);
    expect(find.text('@testuser123'), findsNothing);
    expect(find.byTooltip('Copy username'), findsOneWidget);
    expect(find.text('T'), findsOneWidget);
  });

  testWidgets('a name differing only in case is still not a display name', (
    tester,
  ) async {
    await _pump(tester, _user('TestUser123'));

    expect(find.text('@testuser123'), findsNothing);
    expect(find.text('testuser123'), findsOneWidget);
  });

  testWidgets('a display name keeps the handle line under it', (tester) async {
    await _pump(tester, _user('Tester'));

    expect(find.text('Tester'), findsOneWidget);
    expect(find.text('@testuser123'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('@testuser123')).dy,
      greaterThan(tester.getTopLeft(find.text('Tester')).dy),
    );
  });

  for (final compact in [false, true]) {
    final surface = compact ? 'phone sheet' : 'popover';
    for (final (presence, word) in const [
      (AppPresence.online, 'Online'),
      (AppPresence.away, 'Away'),
      (AppPresence.dnd, 'Do not disturb'),
      (AppPresence.offline, 'Offline'),
    ]) {
      testWidgets('$surface: ${presence.name} is the dot on the avatar, '
          'with no word line', (tester) async {
        await _pump(
          tester,
          _user('Tester'),
          presence: presence,
          compact: compact,
        );

        final dots = _avatarDots(tester);
        expect(dots, hasLength(1));
        expect(dots.single.status, presence);
        expect(
          dots.single.backgroundColor,
          AppTokens.light.surfaceRaised,
          reason: 'the marks cut into the dot show the card, not the page',
        );
        expect(find.text(word), findsNothing);
        expect(
          find.bySemanticsLabel(
            RegExp('^Tester, ${presence.word}\$', multiLine: true),
          ),
          findsOneWidget,
          reason: 'the avatar speaks what the dot shows',
        );
      });
    }
  }

  testWidgets('nobody reported yet draws no dot, as in the member list', (
    tester,
  ) async {
    await _pump(tester, _user('Tester'), presence: AppPresence.unknown);

    expect(_avatarDots(tester), isEmpty);
  });

  testWidgets('appearing offline on your own card is the slashed ring', (
    tester,
  ) async {
    await _pump(
      tester,
      _user('Tester'),
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          api.SessionStore(tokens: _selfSession),
        ),
        meProvider.overrideWith(
          (ref) async => const api.Me(
            id: 'user-test',
            username: 'testuser123',
            displayName: 'Tester',
            createdAt: _nov2026,
            permissions: 0,
          ),
        ),
        presenceControllerProvider.overrideWith(
          (ref) => FakePresence(ref, {'user-test': api.PresenceState.online}),
        ),
        ownVisibilityProvider.overrideWithValue(api.PresenceVisibility.hidden),
      ],
    );

    expect(_avatarDots(tester).single.status, AppPresence.hidden);
  });

  testWidgets('a typed status keeps one line between the handle and the date', (
    tester,
  ) async {
    await _pump(
      tester,
      _user('Tester', statusText: 'heads down until 3'),
      presence: AppPresence.dnd,
    );

    final status = find.text('heads down until 3');
    expect(status, findsOneWidget);
    expect(
      tester.getTopLeft(status).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.text('@testuser123')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Joined Nov 2026')).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(status).dy),
    );
    expect(find.text('-'), findsNothing, reason: 'no presence word to follow');
    expect(find.text('Do not disturb'), findsNothing);
  });

  testWidgets("no typed status leaves no line on someone else's card", (
    tester,
  ) async {
    await _pump(tester, _user('Tester'));

    expect(find.text('Set a status'), findsNothing);
    final handle = tester.getBottomLeft(find.text('@testuser123'));
    final joined = tester.getTopLeft(find.text('Joined Nov 2026'));
    expect(joined.dy - handle.dy, lessThan(4));
  });

  testWidgets('the join date closes the name block, at its left', (
    tester,
  ) async {
    await _pump(tester, _user('Tester', roles: const ['member']));

    final joined = tester.getTopLeft(find.text('Joined Nov 2026'));
    final name = tester.getTopLeft(find.text('Tester'));
    final handle = tester.getBottomLeft(find.text('@testuser123'));
    expect(joined.dx, name.dx);
    expect(joined.dy, greaterThanOrEqualTo(handle.dy));
    expect(
      tester.getTopLeft(find.text('MEMBER')).dy,
      greaterThan(joined.dy),
      reason: 'the role badges follow the identity block',
    );
  });

  testWidgets('no roles leaves no row behind', (tester) async {
    await _pump(tester, _user('Tester'));

    expect(find.text('MEMBER'), findsNothing);
    expect(find.text('Joined Nov 2026'), findsOneWidget);
  });
}
