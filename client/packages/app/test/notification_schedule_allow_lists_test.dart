// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The off-hours "always notify me about" lists: they decide who may notify
/// you outside your schedule, so the add, remove, expand and fallback paths
/// each get a real round trip through a mocked `SlimmApi` and a real store.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/notification_schedule_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/notification_schedule_allow_lists.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _maya = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'Maya',
  createdAt: 0,
);

const _noor = api.UserProfile(
  id: 'user-noor',
  username: 'noor',
  displayName: 'Noor',
  createdAt: 0,
);

class _CountingStore extends MessageStore {
  _CountingStore(super.db);

  int watches = 0;

  @override
  Stream<List<Channel>> watchChannels() {
    watches++;
    return super.watchChannels();
  }
}

class _Wired {
  _Wired(this.store, this.container, this.requests);

  final _CountingStore store;
  final ProviderContainer container;
  final List<String> requests;

  int get scheduleReads =>
      requests.where((r) => r == 'GET /notifications/schedule').length;
}

Future<_Wired> _pump(
  WidgetTester tester,
  Widget child, {
  bool failWrites = false,
}) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final requests = <String>[];
  late final _CountingStore store;
  await tester.runAsync(() async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    store = _CountingStore(db);
    await store.upsertChannels([
      api.Channel(id: 'c-general', name: 'general', kind: 'text', createdAt: 0),
      api.Channel(id: 'c-lounge', name: 'lounge', kind: 'voice', createdAt: 0),
    ]);
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      membersProvider.overrideWith((ref) async => [_maya, _noor]),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            requests.add('${request.method} ${request.url.path}');
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode({'schedule': null}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (failWrites) {
              return http.Response(
                jsonEncode({'error': 'nope'}),
                500,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  final sub = container.listen(notificationScheduleProvider, (_, _) {});
  addTearDown(sub.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Wired(store, container, requests);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 10));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
}

void main() {
  group('people', () {
    const widget = NotificationScheduleAllowedPeople(
      allowedUserIds: ['user-maya', 'user-gone'],
    );

    testWidgets('is a count until expanded, then names each person', (
      tester,
    ) async {
      await _pump(tester, widget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Maya'), findsNothing);

      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();

      expect(find.text('Maya'), findsOneWidget);
      expect(find.text('@maya'), findsOneWidget);
    });

    testWidgets('a person who is not a member any more reads Former member', (
      tester,
    ) async {
      await _pump(tester, widget);
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();

      expect(find.text('Former member'), findsOneWidget);
    });

    testWidgets('Remove deletes that person and refetches the schedule', (
      tester,
    ) async {
      final wired = await _pump(tester, widget);
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      final reads = wired.scheduleReads;

      await tester.tap(find.bySemanticsLabel('Remove').first);
      await tester.pumpAndSettle();

      expect(
        wired.requests,
        contains('DELETE /notifications/schedule/allowed-users/user-maya'),
      );
      expect(wired.scheduleReads, greaterThan(reads));
    });

    testWidgets('Add a person puts the one picked and refetches', (
      tester,
    ) async {
      final wired = await _pump(tester, widget);
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      final reads = wired.scheduleReads;

      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Noor'));
      await tester.pumpAndSettle();

      expect(
        wired.requests,
        contains('PUT /notifications/schedule/allowed-users/user-noor'),
      );
      expect(wired.scheduleReads, greaterThan(reads));
    });

    testWidgets('a refused remove is a persistent error, not a SnackBar', (
      tester,
    ) async {
      final wired = await _pump(tester, widget, failWrites: true);
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      final reads = wired.scheduleReads;

      await tester.tap(find.bySemanticsLabel('Remove').first);
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(wired.scheduleReads, reads, reason: 'nothing changed to refetch');
    });
  });

  group('channels', () {
    const widget = NotificationScheduleAllowedChannels(
      allowedChannelIds: ['c-general', 'c-lounge', 'c-gone'],
    );

    testWidgets('subscribes to the store only once expanded', (tester) async {
      final wired = await _pump(tester, widget);
      expect(wired.store.watches, 0);

      await tester.tap(find.text('Channels'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(wired.store.watches, 1, reason: 'one subscription, not per build');
      await _unmount(tester);
    });

    testWidgets('collapsing and expanding again still lists the channels', (
      tester,
    ) async {
      await _pump(tester, widget);
      await tester.tap(find.text('Channels'));
      await _settle(tester);
      await tester.tap(find.text('Channels'));
      await tester.pumpAndSettle();
      expect(find.text('general'), findsNothing);

      await tester.tap(find.text('Channels'));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('general'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('names channels, marks voice, and falls back to Former', (
      tester,
    ) async {
      await _pump(tester, widget);
      await tester.tap(find.text('Channels'));
      await _settle(tester);

      expect(find.text('general'), findsOneWidget);
      expect(find.text('lounge'), findsOneWidget);
      expect(find.text('Former channel'), findsOneWidget);
      expect(find.byIcon(AppIcons.voice), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('Remove deletes that channel and refetches the schedule', (
      tester,
    ) async {
      final wired = await _pump(tester, widget);
      await tester.tap(find.text('Channels'));
      await _settle(tester);
      final reads = wired.scheduleReads;

      await tester.tap(find.bySemanticsLabel('Remove').first);
      await tester.pumpAndSettle();

      expect(
        wired.requests,
        contains('DELETE /notifications/schedule/allowed-channels/c-general'),
      );
      expect(wired.scheduleReads, greaterThan(reads));
      await _unmount(tester);
    });

    testWidgets('Add a channel puts the one picked and refetches', (
      tester,
    ) async {
      final wired = await _pump(tester, widget);
      await tester.tap(find.text('Channels'));
      await _settle(tester);
      final reads = wired.scheduleReads;

      await tester.tap(find.text('Add a channel'));
      await _settle(tester);
      await tester.tap(find.text('lounge').last);
      await tester.pumpAndSettle();

      expect(
        wired.requests,
        contains('PUT /notifications/schedule/allowed-channels/c-lounge'),
      );
      expect(wired.scheduleReads, greaterThan(reads));
      await _unmount(tester);
    });

    testWidgets('a refused remove is a persistent error, not a SnackBar', (
      tester,
    ) async {
      await _pump(tester, widget, failWrites: true);
      await tester.tap(find.text('Channels'));
      await _settle(tester);

      await tester.tap(find.bySemanticsLabel('Remove').first);
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await _unmount(tester);
    });
  });
}
