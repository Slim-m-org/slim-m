// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `DirectMessagesSection` mounts every DM row at once, so a call state
/// poller owned per-row multiplies with the DM list. This pins the property
/// that regression would break: mounting many DM rows at once must not
/// become one simultaneous roster request per row, which is what emptied
/// the write-class rate budget (`ratelimit.rs`'s burst of 30) the instant a
/// DM-heavy rail rendered and could 429 a message send landing in the same
/// window. See `providers/dm_call_activity.dart`'s own doc comment.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/dm_call_activity.dart';
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/dm_row.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _rowCount = 12;

Channel _dm(int i) => Channel(
  id: 'dm-$i',
  name: 'Peer $i',
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmParticipantId: 'user-$i',
);

Widget _harness(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    theme: buildTheme(Brightness.light, AppTokens.light),
    routerConfig: GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Column(
              children: [
                for (var i = 0; i < _rowCount; i++)
                  DmRow(channel: _dm(i), selected: false),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/channels/:channelId',
          builder: (context, state) => Scaffold(
            body: Text('channel:${state.pathParameters['channelId']}'),
          ),
        ),
      ],
    ),
  ),
);

void main() {
  testWidgets(
    'mounting many DM rows at once queues their roster lookups rather than '
    'firing one simultaneous request per row',
    (tester) async {
      var concurrent = 0;
      var peakConcurrent = 0;
      final gates = <String, Completer<void>>{};
      final requested = <String>{};

      final db = SlimmDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          liveEventsProvider.overrideWithValue(const Stream.empty()),
          databaseProvider.overrideWith((ref) async {
            ref.onDispose(db.close);
            return db;
          }),
          mockApiOverride((request) async {
            if (!request.url.path.endsWith('/voice/roster')) {
              return http.Response('', 204);
            }
            final channelId = RegExp(
              r'/channels/([^/]+)/voice/roster',
            ).firstMatch(request.url.path)!.group(1)!;
            requested.add(channelId);
            concurrent++;
            peakConcurrent = concurrent > peakConcurrent
                ? concurrent
                : peakConcurrent;
            final gate = gates.putIfAbsent(channelId, () => Completer<void>());
            await gate.future;
            concurrent--;
            return http.Response(
              jsonEncode({'participants': <Object>[]}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(container));
      await tester.pump();
      await tester.pump();

      expect(
        peakConcurrent,
        dmCallActivityMaxConcurrentFetches,
        reason:
            'every DM row mounted at once must not become one simultaneous '
            'roster request per row - concurrency stays bounded even though '
            '$_rowCount rows exist',
      );
      expect(
        peakConcurrent,
        lessThan(_rowCount),
        reason: 'the whole point of the bound: fewer in flight than rows',
      );

      // Releases every gate, including ones not yet reached, so nothing is left pending.
      for (var i = 0; i < _rowCount; i++) {
        gates.putIfAbsent('dm-$i', () => Completer<void>()).complete();
      }
      await tester.pumpAndSettle();

      expect(
        requested.length,
        _rowCount,
        reason: 'bounding concurrency must still reach every row eventually',
      );
    },
  );
}
