// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression tests for `membersProvider` fetching with no `limit`, so the
/// server's own default of 50 silently truncated any roster past that, plus
/// `memberModerationWatcherProvider`'s roster refetch on a real
/// [api.MemberJoined] event.
///
/// That refetch used to be a keep-alive guard that inferred a join from a
/// presence frame or a first message, with its own debounce and a one-refetch
/// bound for an id that could never appear; `Event::MemberJoined` on the
/// server replaced all of that, so the second group below now also checks
/// the inference is gone, not just that the real event works.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Zero-padded so lexicographic id order matches numeric order, the way a
/// real UUIDv7 roster is already ordered by creation.
String _id(int n) => 'u${n.toString().padLeft(3, '0')}';

Map<String, dynamic> _memberJson(String id) => {
  'id': id,
  'username': id,
  'display_name': id,
  'created_at': 0,
};

/// A `/members` fake that pages the way the real server does: `after`
/// selects everything past that id, and the response never exceeds
/// [serverMaxLimit] regardless of what was asked for, so a caller that
/// forgets to send `limit` gets the server's own smaller default rather
/// than everything.
http.Response _membersPage(
  http.Request request,
  List<String> allIds, {
  required int serverMaxLimit,
  int serverDefaultLimit = 50,
}) {
  final query = request.url.queryParameters;
  final after = query['after'];
  final requested = int.tryParse(query['limit'] ?? '') ?? serverDefaultLimit;
  final limit = requested.clamp(1, serverMaxLimit).toInt();
  final ids = after == null
      ? allIds
      : allIds.where((id) => id.compareTo(after) > 0).toList();
  final page = ids.take(limit).toList();
  return http.Response(jsonEncode(page.map(_memberJson).toList()), 200);
}

ProviderContainer _containerWith({
  required http.Client httpClient,
  Stream<api.ServerEvent>? liveEvents,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: httpClient,
        );
        ref.onDispose(client.close);
        return client;
      }),
      if (liveEvents != null) liveEventsProvider.overrideWithValue(liveEvents),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('membersProvider paging', () {
    test(
      'a roster of 60 resolves to all 60, not the server default page of 50',
      () async {
        final allIds = [for (var i = 0; i < 60; i++) _id(i)];
        final container = _containerWith(
          httpClient: MockClient(
            (request) async =>
                _membersPage(request, allIds, serverMaxLimit: 200),
          ),
        );
        container.listen(membersProvider, (_, __) {});

        final members = await container.read(membersProvider.future);

        expect(members, hasLength(60));
        expect(members.map((m) => m.id).toSet(), allIds.toSet());
      },
    );

    test(
      'a roster bigger than one server page is followed across requests',
      () async {
        final allIds = [for (var i = 0; i < 250; i++) _id(i)];
        var requestCount = 0;
        final container = _containerWith(
          httpClient: MockClient((request) async {
            requestCount++;
            return _membersPage(request, allIds, serverMaxLimit: 200);
          }),
        );
        container.listen(membersProvider, (_, __) {});

        final members = await container.read(membersProvider.future);

        expect(members, hasLength(250));
        expect(
          requestCount,
          2,
          reason: '250 members needs two 200-row pages, not one truncated one',
        );
      },
    );
  });

  testWidgets('the pane header counts the full roster, not one truncated '
      'page', (tester) async {
    final allIds = [for (var i = 0; i < 60; i++) _id(i)];
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
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
                return http.Response('[]', 200);
              }
              return _membersPage(request, allIds, serverMaxLimit: 200);
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
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

    expect(find.textContaining('MEMBERS · 60'), findsOneWidget);
  });

  group('member roster refetch on a real join', () {
    test('a MemberJoined event refetches the roster', () async {
      var fetchCount = 0;
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = _containerWith(
        httpClient: MockClient((request) async {
          fetchCount++;
          return _membersPage(request, [_id(1)], serverMaxLimit: 200);
        }),
        liveEvents: events.stream,
      );
      final watcherSub = container.listen(
        memberModerationWatcherProvider,
        (_, __) {},
      );
      final membersSub = container.listen(membersProvider, (_, __) {});
      await container.read(membersProvider.future);
      expect(fetchCount, 1);

      events.add(const api.MemberJoined(userId: 'u002'));
      await Future<void>.delayed(memberRosterRefetchDelay * 2);
      // Re-read, or an unread invalidation passes; see the library doc.
      await container.read(membersProvider.future);
      expect(fetchCount, 2, reason: 'a real join must refetch the roster');

      watcherSub.close();
      membersSub.close();
    });

    test(
      'a presence change alone no longer refetches; only MemberJoined does',
      () async {
        var fetchCount = 0;
        final events = StreamController<api.ServerEvent>.broadcast();
        addTearDown(events.close);
        final container = _containerWith(
          httpClient: MockClient((request) async {
            fetchCount++;
            return _membersPage(request, [_id(1)], serverMaxLimit: 200);
          }),
          liveEvents: events.stream,
        );
        final watcherSub = container.listen(
          memberModerationWatcherProvider,
          (_, __) {},
        );
        final membersSub = container.listen(membersProvider, (_, __) {});
        await container.read(membersProvider.future);
        expect(fetchCount, 1);

        events.add(
          const api.PresenceChanged(
            userId: 'ghost',
            status: api.PresenceState.online,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await container.read(membersProvider.future);
        expect(
          fetchCount,
          1,
          reason:
              'a presence frame is no longer read as an inferred join now '
              'that the server sends a real MemberJoined event',
        );

        watcherSub.close();
        membersSub.close();
      },
    );
  });
}
