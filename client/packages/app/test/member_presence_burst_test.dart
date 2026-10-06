// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A burst of roster events costs about one roster crawl, and a crawl that an
/// invalidation has already replaced stops asking for pages.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<int> _countRequests({
  required bool sameTick,
  int roster = 450,
  Completer<void>? firstPageGate,
}) async {
  var requests = 0;
  final all = [
    for (var i = 0; i < roster; i++)
      {
        'id': 'u${i.toString().padLeft(4, '0')}',
        'username': 'user$i',
        'display_name': 'User $i',
        'created_at': 0,
      },
  ];
  final events = StreamController<api.ServerEvent>.broadcast();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path != '/members') return http.Response('[]', 200);
            requests++;
            if (requests == 1 && firstPageGate != null) {
              await firstPageGate.future;
            }
            final after = request.url.queryParameters['after'];
            final start = after == null
                ? 0
                : all.indexWhere((m) => m['id'] == after) + 1;
            final page = all.skip(start).take(200).toList();
            return http.Response(
              jsonEncode(page),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      ),
      liveEventsProvider.overrideWithValue(events.stream),
    ],
  );
  final watcher = container.listen(memberModerationWatcherProvider, (_, _) {});
  // The member pane being open: something is listening to the roster.
  final pane = container.listen(membersProvider, (_, _) {});
  if (firstPageGate == null) {
    await container.read(membersProvider.future);
    requests = 0;
  }

  for (var i = 0; i < 20; i++) {
    events.add(api.MemberRoleChanged(userId: 'u$i', roleId: 'r1'));
    if (!sameTick) await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(memberRosterRefetchDelay * 2);
  firstPageGate?.complete();
  await container.read(membersProvider.future);
  await Future<void>.delayed(const Duration(milliseconds: 50));
  watcher.close();
  pane.close();
  container.dispose();
  await events.close();
  return requests;
}

void main() {
  test('20 role events in one tick cost one crawl', () async {
    expect(await _countRequests(sameTick: true), lessThanOrEqualTo(3));
  });

  test('20 role events as separate frames cost one crawl', () async {
    expect(await _countRequests(sameTick: false), lessThanOrEqualTo(3));
  });

  test('a crawl replaced mid-flight stops asking for pages', () async {
    final n = await _countRequests(
      sameTick: true,
      firstPageGate: Completer<void>(),
    );

    // The abandoned crawl's one in-flight page, then the new crawl's three.
    expect(n, lessThanOrEqualTo(4));
  });
}
