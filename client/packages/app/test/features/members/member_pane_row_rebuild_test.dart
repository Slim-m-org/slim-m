// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Proves the CS1 rebuild-scoping fix: a live `PresenceChanged` for one
/// member must rebuild only that member's row in the pane, not every row.
/// `MemberRow` watches its own id via `presenceControllerProvider.select`
/// rather than the pane handing it a `status` computed from the whole map,
/// so a change to one member's presence should never touch another's row.
///
/// Uses [debugMemberRowBuildCounts] (test-only, in `member_pane_rows.dart`)
/// rather than reading the screen: a rendered frame looks identical whether
/// or not a row's `build` actually reran, so nothing else can tell the two
/// apart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/providers/member_selection.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

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

/// Same shape as the other member-pane tests' `_fakeApi`: `/me` and
/// `/presence` answered from canned data, everything else fails loudly.
SlimmApi _fakeApi(
  SessionStore session, {
  Map<String, PresenceState> presence = const {},
}) {
  return SlimmApi(
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
      if (request.url.path == '/presence') {
        final ids = request.url.queryParameters['ids']?.split(',') ?? [];
        final body = [
          for (final id in ids)
            if (presence[id] != null)
              {'user_id': id, 'status': presence[id]!.name},
        ];
        return http.Response(jsonEncode(body), 200);
      }
      throw StateError('unexpected request in this test: ${request.url}');
    }),
  );
}

void main() {
  testWidgets(
    "a PresenceChanged for one member rebuilds only that member's row",
    (tester) async {
      debugResetMemberRowBuildCounts();
      final members = [_profile('a', 'Anna'), _profile('b', 'Bo')];
      final events = StreamController<ServerEvent>.broadcast();
      addTearDown(events.close);

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final api = _fakeApi(
              ref.watch(sessionProvider),
              // Both online in one section, so grouping never changes and only a row's own scoped watch can rebuild it.
              presence: {'a': PresenceState.online, 'b': PresenceState.online},
            );
            ref.onDispose(api.close);
            return api;
          }),
          liveEventsProvider.overrideWithValue(events.stream),
          membersProvider.overrideWith((ref) async => members),
          channelMembersProvider.overrideWith((ref, _) async => members),
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

      expect(find.text('Anna'), findsOneWidget);
      expect(find.text('Bo'), findsOneWidget);
      expect(debugMemberRowBuildCounts['a'], 1);
      expect(debugMemberRowBuildCounts['b'], 1);

      events.add(
        const PresenceChanged(userId: 'a', status: PresenceState.away),
      );
      await tester.pumpAndSettle();

      expect(
        debugMemberRowBuildCounts['a'],
        2,
        reason: "the row for the member whose presence changed must rebuild",
      );
      expect(
        debugMemberRowBuildCounts['b'],
        1,
        reason:
            "a presence change for a different member must not rebuild "
            "this row",
      );
    },
  );

  testWidgets('selecting one member rebuilds only that member\'s row', (
    tester,
  ) async {
    debugResetMemberRowBuildCounts();
    final members = [_profile('a', 'Anna'), _profile('b', 'Bo')];
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = _fakeApi(
            ref.watch(sessionProvider),
            presence: {'a': PresenceState.online, 'b': PresenceState.online},
          );
          ref.onDispose(api.close);
          return api;
        }),
        liveEventsProvider.overrideWithValue(events.stream),
        membersProvider.overrideWith((ref) async => members),
        channelMembersProvider.overrideWith((ref, _) async => members),
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

    // Entering the mode changes every row's `selecting`, so all rebuild once.
    container.read(memberSelectionProvider.notifier).enter();
    await tester.pumpAndSettle();
    final afterEnter = {
      'a': debugMemberRowBuildCounts['a'],
      'b': debugMemberRowBuildCounts['b'],
    };

    container.read(memberSelectionProvider.notifier).toggle('a');
    await tester.pumpAndSettle();

    expect(
      debugMemberRowBuildCounts['a'],
      afterEnter['a']! + 1,
      reason: "the row that was picked must rebuild to show it",
    );
    expect(
      debugMemberRowBuildCounts['b'],
      afterEnter['b'],
      reason:
          "picking one member must not rebuild the rest of the roster: the "
          "selection set is a new object every toggle, so an unscoped watch "
          "would rebuild all of them",
    );
  });
}
