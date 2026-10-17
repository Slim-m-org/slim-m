// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail has two indicators a reader can take for connection status, and
/// this pins which one actually is.
///
/// The owner, from the real iOS app on 2026-09-30: "I'm less convinced the
/// bottom bar connected ui is truly connected". He was right, and it was not a
/// misreading. The footer returned the literal word `connected` with a green
/// online dot whenever no status had been picked, so it said "connected" with
/// the socket down, beside a header dot correctly reading offline.
///
/// The footer's line is a presence line now and says nothing about the socket,
/// so the two cannot disagree. That is asserted as disjoint vocabularies rather
/// than case by case: a word added to either side later has to stay on its own
/// side of the line.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/sync_failure.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container(SyncStatus status) => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    syncControllerProvider.overrideWith(
      (ref) => StubSyncController(ref, status),
    ),
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
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '{}',
            404,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      ref.onDispose(client.close);
      return client;
    }),
  ],
);

Future<void> _pumpFooter(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Align(alignment: Alignment.bottomLeft, child: RailUserFooter()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every second line the footer can render: the presence vocabulary.
final _footerWords = [for (final state in AppPresence.values) ?state.word];

void main() {
  test('nothing the footer can say is something the connection indicator '
      'can say', () {
    final connectionWords = {
      for (final status in SyncStatus.values)
        for (final failure in [null, ...SyncFailure.values])
          connectionLabel(status, failure),
    };
    for (final word in _footerWords) {
      expect(
        connectionWords,
        isNot(contains(word)),
        reason:
            '"$word" would let the footer and the header dot answer the same '
            'question, which is how "connected" ended up in the footer',
      );
    }
  });

  test('a refused session never reads as a connection worth waiting out', () {
    expect(
      connectionLabel(SyncStatus.offline, SyncFailure.refused),
      isNot(connectionLabel(SyncStatus.offline, SyncFailure.unreachable)),
    );
    expect(
      connectionLabel(SyncStatus.offline, SyncFailure.refused),
      isNot(contains('retrying')),
      reason: 'the loop does keep trying; inviting a wait for it is the lie',
    );
    expect(
      connectionLabel(SyncStatus.offline, SyncFailure.unreachable),
      connectionLabel(SyncStatus.offline, null),
      reason: 'an unknown cause must not read differently from the common one',
    );
  });

  testWidgets('with the socket down and no status chosen, the footer says no '
      'connection word', (tester) async {
    final container = _container(SyncStatus.offline);
    addTearDown(container.dispose);
    await _pumpFooter(tester, container);

    expect(find.text('online'), findsOneWidget);
    for (final status in SyncStatus.values) {
      for (final failure in [null, ...SyncFailure.values]) {
        expect(
          find.text(connectionLabel(status, failure)),
          findsNothing,
          reason: 'the socket is down; this row must not speak for it at all',
        );
      }
    }
  });

  testWidgets('the footer line does not move when the socket does, so it '
      'cannot contradict the header dot', (tester) async {
    final lines = <SyncStatus, String>{};
    for (final status in SyncStatus.values) {
      final container = _container(status);
      container.read(presenceVisibilityDisplayProvider.notifier).state =
          api.PresenceVisibility.away;
      await _pumpFooter(tester, container);
      lines[status] = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>()
          .firstWhere(_footerWords.contains);
      container.dispose();
    }

    expect(
      lines.values.toSet(),
      {'away'},
      reason:
          'a chosen status is the person\'s own and outlives a reconnect; the '
          'header dot is the only thing that moves with the socket',
    );
  });
}
