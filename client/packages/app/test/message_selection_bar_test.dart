// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bar that replaces the composer while messages are being selected, and
/// the request the delete on it actually sends.
///
/// The request is the part worth pinning. `bulkDeleteMessages` shipped in
/// #675 with no caller at all, so nothing until now proved the client can
/// reach it; and a delete that quietly looped the single-message endpoint
/// instead would look identical on screen while losing every property the
/// bulk route exists for - one transaction, one audit entry per author, and
/// a bounded number of round trips while a raid is still arriving.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_actions.dart';
import 'package:slimm_app/src/providers/message_selection.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/message_selection_bar.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _channel = 'c1';
const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Every request the widget under test caused, in order.
final List<String> requests = [];
final List<Object?> bodies = [];

api.SlimmApi _api(api.SessionStore session) => api.SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: session,
  httpClient: MockClient((request) async {
    requests.add('${request.method} ${request.url.path}');
    if (request.body.isNotEmpty) bodies.add(jsonDecode(request.body));
    return http.Response('', 204);
  }),
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Future<void> Function()? onDelete,
  MessageStore? storeOverride,
  void Function(WidgetRef)? captureRef,
}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = _api(ref.watch(sessionProvider));
        ref.onDispose(api.close);
        return api;
      }),
      if (storeOverride case final MessageStore s)
        storeProvider.overrideWith((ref) async => s),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              captureRef?.call(ref);
              return MessageSelectionBar(
                channelId: _channel,
                onDelete: onDelete ?? () async {},
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() {
    requests.clear();
    bodies.clear();
  });

  testWidgets('the count is what the delete is about to act on', (
    tester,
  ) async {
    final container = await _pump(tester);
    final selection = container.read(
      messageSelectionProvider(_channel).notifier,
    );
    selection.start('m1');
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    selection.toggle('m2');
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('an empty selection cannot be deleted', (tester) async {
    var deletes = 0;
    final container = await _pump(tester, onDelete: () async => deletes++);
    container.read(messageSelectionProvider(_channel).notifier).start('m1');
    await tester.pumpAndSettle();
    container.read(messageSelectionProvider(_channel).notifier).toggle('m1');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deletes, 0, reason: 'the button is disabled, not merely unhelpful');
  });

  testWidgets('cancel leaves the mode', (tester) async {
    final container = await _pump(tester);
    container.read(messageSelectionProvider(_channel).notifier).start('m1');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(messageSelectionProvider(_channel)).active, isFalse);
  });

  testWidgets('a full selection says why it stopped growing', (tester) async {
    final container = await _pump(tester);
    final selection = container.read(
      messageSelectionProvider(_channel).notifier,
    );
    selection.start('m0');
    for (var i = 1; i < maxBulkDeleteIds; i++) {
      selection.toggle('m$i');
    }
    await tester.pumpAndSettle();

    expect(
      find.textContaining('the most at once'),
      findsOneWidget,
      reason: 'a control that silently stops responding reads as broken',
    );
  });

  testWidgets('deleting sends one bulk request and drops the local rows', (
    tester,
  ) async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(
        id: _channel,
        name: 'general',
        kind: 'text',
        createdAt: 0,
      ),
    ]);
    await store.applyMessages([
      for (var i = 1; i <= 4; i++)
        api.Message(
          id: 'm$i',
          channelId: _channel,
          authorId: 'spammer',
          authorDisplayName: 'spammer',
          seq: i,
          content: 'spam $i',
          createdAt: i * 1000,
          editedAt: null,
        ),
    ]);

    late WidgetRef capturedRef;
    final container = await _pump(
      tester,
      storeOverride: store,
      captureRef: (r) => capturedRef = r,
    );
    container.read(messageSelectionProvider(_channel).notifier)
      ..start('m1')
      ..toggle('m2')
      ..toggle('m3');
    await tester.pumpAndSettle();

    // runAsync: under testWidgets' FakeAsync drift's stream never delivers.
    await tester.runAsync(
      () => bulkDeleteMessagesAction(
        capturedRef.read,
        channelId: _channel,
        messageIds: container
            .read(messageSelectionProvider(_channel))
            .ids
            .toList(),
      ),
    );

    expect(requests, [
      'POST /channels/$_channel/messages/bulk-delete',
    ], reason: 'one request, not a loop over the single-delete route');
    expect(
      (bodies.single! as Map)['message_ids'],
      unorderedEquals(['m1', 'm2', 'm3']),
      reason: 'every selected id travels in that one request',
    );

    final left = (await tester.runAsync(
      () => store.watchChannel(_channel).first,
    ))!;
    expect(
      left.map((m) => m.id),
      ['m4'],
      reason:
          'the deleted rows go immediately rather than waiting for the '
          'message.deleted broadcast to come back round',
    );
  });
}
