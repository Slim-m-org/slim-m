// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who is offered the member pane's selection mode, and what a row does while
/// it is running.
///
/// The gate is the point. A member with neither moderation bit must not be
/// offered the mode at all: the server refuses their batch either way, so
/// offering it would be a control that exists only to fail. And once the mode
/// is on, a row has to pick rather than open - a pane where tapping a member
/// still opened their profile would make the mode unusable, since choosing
/// thirty people means thirty taps.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/member_selection.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _selectLabel = 'Select members to moderate';

UserProfile _profile(String id, String name) => UserProfile(
  id: id,
  username: name.toLowerCase(),
  displayName: name,
  createdAt: 0,
);

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

SlimmApi _fakeApi(SessionStore session) => SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: session,
  httpClient: MockClient((request) async {
    if (request.url.path == '/me') {
      return http.Response(
        jsonEncode({
          'id': 'self',
          'username': 'self',
          'display_name': 'Self',
          'created_at': 0,
          'permissions': 0,
        }),
        200,
      );
    }
    return http.Response(jsonEncode(const <String, Object?>{}), 200);
  }),
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required int mine,
  double? width,
}) async {
  if (width != null) {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = _fakeApi(ref.watch(sessionProvider));
        ref.onDispose(api.close);
        return api;
      }),
      membersProvider.overrideWith(
        (ref) async => [_profile('1', 'Priya'), _profile('2', 'Kess')],
      ),
      channelMembersProvider.overrideWith(
        (ref, _) async => [_profile('1', 'Priya'), _profile('2', 'Kess')],
      ),
      myPermissionsProvider.overrideWithValue(mine),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: AppMemberPane(channelId: 'c1')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('a member holding neither bit is not offered the mode', (
    tester,
  ) async {
    await _pump(tester, mine: 0);
    expect(find.bySemanticsLabel(_selectLabel), findsNothing);
  });

  testWidgets('KICK_MEMBERS alone is enough to be offered it', (tester) async {
    await _pump(tester, mine: Perm.kickMembers);
    expect(find.bySemanticsLabel(_selectLabel), findsOneWidget);
  });

  testWidgets('BAN_MEMBERS alone is enough to be offered it', (tester) async {
    await _pump(tester, mine: Perm.banMembers);
    expect(find.bySemanticsLabel(_selectLabel), findsOneWidget);
  });

  testWidgets(
    'entering the mode shows the bar naming what a viewer holding only '
    'BAN_MEMBERS can do with a selection',
    (tester) async {
      final container = await _pump(tester, mine: Perm.banMembers);
      await tester.tap(find.bySemanticsLabel(_selectLabel));
      await tester.pumpAndSettle();

      expect(container.read(memberSelectionProvider).active, isTrue);
      expect(container.read(memberSelectionProvider).count, 0);
      expect(find.text('Tap members to remove'), findsOneWidget);
    },
  );

  testWidgets(
    'a viewer holding only KICK_MEMBERS is told the mode is for timing out',
    (tester) async {
      await _pump(tester, mine: Perm.kickMembers);
      await tester.tap(find.bySemanticsLabel(_selectLabel));
      await tester.pumpAndSettle();

      expect(find.text('Tap members to time out'), findsOneWidget);
    },
  );

  testWidgets(
    'a viewer holding both bits is told the mode covers either verb',
    (tester) async {
      await _pump(tester, mine: Perm.kickMembers | Perm.banMembers);
      await tester.tap(find.bySemanticsLabel(_selectLabel));
      await tester.pumpAndSettle();

      expect(find.text('Tap members to time out or remove'), findsOneWidget);
    },
  );

  // The owner: rows looked identical to normal with no "tap to select" affordance. Proven at a phone and a desktop width.
  for (final width in [390.0, 1000.0]) {
    testWidgets(
      'at ${width.toInt()}px, an unselected row carries a visible pick '
      'affordance once the mode is on',
      (tester) async {
        await _pump(tester, mine: Perm.banMembers, width: width);
        expect(find.byType(AppListRow), findsNWidgets(2));

        final before = tester.getTopLeft(find.text('Priya'));
        await tester.tap(find.bySemanticsLabel(_selectLabel));
        await tester.pumpAndSettle();

        final after = tester.getTopLeft(find.text('Priya'));
        expect(
          after.dx,
          greaterThan(before.dx),
          reason:
              'a pick affordance in front of the row must push its label '
              'right, or the mode looks unchanged',
        );
      },
    );
  }

  testWidgets('a row picks rather than opens while the mode is on', (
    tester,
  ) async {
    final container = await _pump(tester, mine: Perm.banMembers);
    await tester.tap(find.bySemanticsLabel(_selectLabel));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Priya'));
    await tester.pumpAndSettle();

    expect(container.read(memberSelectionProvider).contains('1'), isTrue);
    // The profile sheet would have put the member's own name in a heading.
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('the affordance goes away while the mode is already running', (
    tester,
  ) async {
    await _pump(tester, mine: Perm.banMembers);
    await tester.tap(find.bySemanticsLabel(_selectLabel));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(_selectLabel), findsNothing);
  });

  testWidgets('a roster that fails mid-selection still offers a way out', (
    tester,
  ) async {
    // Pins the bug: the bar lived inside the roster's `data` branch, so a failed refetch took the only Cancel with it.
    var fails = false;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = _fakeApi(ref.watch(sessionProvider));
          ref.onDispose(api.close);
          return api;
        }),
        membersProvider.overrideWith((ref) async {
          if (fails) throw const TransportException('offline');
          return [_profile('1', 'Priya')];
        }),
        channelMembersProvider.overrideWith((ref, _) async {
          if (fails) throw const TransportException('offline');
          return [_profile('1', 'Priya')];
        }),
        myPermissionsProvider.overrideWithValue(Perm.banMembers),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: AppMemberPane(channelId: 'c1')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel(_selectLabel));
    await tester.pumpAndSettle();
    expect(container.read(memberSelectionProvider).active, isTrue);

    fails = true;
    container.invalidate(channelMembersProvider);
    await tester.pumpAndSettle();

    expect(find.text('Could not load members.'), findsOneWidget);
    expect(
      find.text('Cancel'),
      findsOneWidget,
      reason: 'the mode is still on, so its way out must still be on screen',
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(memberSelectionProvider).active, isFalse);
  });

  testWidgets('losing both moderation bits ends the mode', (tester) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = _fakeApi(ref.watch(sessionProvider));
          ref.onDispose(api.close);
          return api;
        }),
        membersProvider.overrideWith((ref) async => [_profile('1', 'Priya')]),
        channelMembersProvider.overrideWith(
          (ref, _) async => [_profile('1', 'Priya')],
        ),
        myPermissionsProvider.overrideWith((ref) => ref.watch(_perms)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: AppMemberPane(channelId: 'c1')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel(_selectLabel));
    await tester.pumpAndSettle();
    expect(container.read(memberSelectionProvider).active, isTrue);

    container.read(_perms.notifier).state = 0;
    await tester.pumpAndSettle();

    expect(
      container.read(memberSelectionProvider).active,
      isFalse,
      reason: 'a mode with no verb left in it should not stay open',
    );
  });
}

/// Stands in for whatever feeds `myPermissionsProvider`, so a test can revoke
/// a bit mid-session the way losing a role would.
final _perms = StateProvider<int>((ref) => Perm.banMembers);
