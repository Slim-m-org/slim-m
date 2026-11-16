// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The identity block of a member card: someone with no display name of their
/// own shows their username once, and the join date sits under the presence
/// line rather than alone at the right.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/presence_view.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_design_system/design_system.dart';

const _nov2026 = 1793750400000;

api.UserProfile _user(String displayName, {List<String> roles = const []}) =>
    api.UserProfile(
      id: 'user-test',
      username: 'testuser123',
      displayName: displayName,
      createdAt: _nov2026,
      roles: roles,
      profileColor: 2,
    );

Future<void> _pump(WidgetTester tester, api.UserProfile profile) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        membersProvider.overrideWith((ref) async => [profile]),
        presenceForProvider.overrideWith((ref, id) => AppPresence.offline),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MemberProfileBody(
              profile: profile,
              compact: false,
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

  testWidgets('the join date sits under the presence line, at its left', (
    tester,
  ) async {
    await _pump(tester, _user('Tester', roles: const ['member']));

    final joined = tester.getTopLeft(find.text('Joined Nov 2026'));
    final name = tester.getTopLeft(find.text('Tester'));
    final presence = tester.getBottomLeft(find.text('Offline'));
    expect(joined.dx, name.dx);
    expect(joined.dy, greaterThanOrEqualTo(presence.dy));
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
