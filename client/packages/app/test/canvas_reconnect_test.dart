// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one property that lives in `CanvasPane`'s own Riverpod wiring rather
/// than in `CanvasSync` itself: a transition into `SyncStatus.live` runs
/// exactly one catch-up, however many times the pane rebuilds around it.
/// Mirrors `canvas_pane_test.dart`'s own "exactly one viewport request"
/// guard, which the same class of bug (a subscription re-registered on every
/// rebuild) would also break.
///
/// Also covers `CanvasMediaSlotSync.fetch`, which rides the identical
/// transition for the identical reason: a slot carries no seq, so nothing
/// else notices a `canvas.media_slot.changed` frame missed while the socket
/// was down.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

class _ManualSyncController extends SyncController {
  _ManualSyncController(super.ref);

  @override
  Future<void> start() async {}

  void emit(SyncStatus status) => state = status;
}

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('a transition into SyncStatus.live runs exactly one catch-up', (
    tester,
  ) async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    var opsGets = 0;
    var slotGets = 0;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        syncControllerProvider.overrideWith(_ManualSyncController.new),
        liveEventsProvider.overrideWithValue(events.stream),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path.endsWith('/canvas/ops')) {
                opsGets++;
                final afterSeq = int.parse(
                  request.url.queryParameters['after_seq']!,
                );
                return _json({
                  'ops': <Object>[],
                  'latest_seq': afterSeq,
                  'has_more': false,
                  'reset': false,
                });
              }
              if (request.url.path.endsWith('/canvas/media-slots')) {
                slotGets++;
                return _json({'slots': <Object>[]});
              }
              if (request.url.path.endsWith('/canvas/object-locks')) {
                return _json({'object_ids': <Object>[]});
              }
              if (!request.url.path.endsWith('/canvas/objects')) {
                return _json(<Object>[]);
              }
              return _json({
                'objects': <Object>[],
                'has_more': false,
                'latest_seq': 0,
              });
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
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(body: CanvasPane(channelId: 'c1')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final afterMount = opsGets;
    expect(slotGets, 1, reason: 'initState fetches the slots once');

    final controller =
        container.read(syncControllerProvider.notifier)
            as _ManualSyncController;

    controller.emit(SyncStatus.live);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      opsGets,
      afterMount + 1,
      reason: 'one transition into live must run exactly one catch-up',
    );
    expect(
      slotGets,
      2,
      reason:
          'a slot carries no seq of its own, so a reconnect must refetch it '
          'the same way it refetches canvas ops, or a live frame missed '
          'during the gap leaves the tile stale forever',
    );

    // A rebuild with no further transition must not run a second one.
    controller.emit(SyncStatus.live);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      opsGets,
      afterMount + 1,
      reason: 'the same value again is not a transition, and must not re-fire',
    );
    expect(slotGets, 2, reason: 'the same value again must not re-fire');

    // A genuine second reconnect - offline, then live again - does.
    controller.emit(SyncStatus.offline);
    controller.emit(SyncStatus.live);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(opsGets, afterMount + 2);
    expect(slotGets, 3);
  });
}
