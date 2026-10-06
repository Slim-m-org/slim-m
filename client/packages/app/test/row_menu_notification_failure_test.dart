// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel or DM row's mute, off-hours and mark-unread entries close the
/// menu before the server answers, so a refusal has to be said somewhere that
/// outlives it rather than thrown into the zone or dropped.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/dms.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/widgets/dm_row.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Channel _channel(String id, String name, {String? dmPeer}) => Channel(
  id: id,
  name: name,
  kind: dmPeer == null ? 'text' : dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 5,
  lastReadSeq: 5,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmParticipantId: dmPeer,
);

ProviderContainer _container() {
  final db = SlimmDatabase(NativeDatabase.memory());
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      databaseProvider.overrideWith((ref) async {
        ref.onDispose(db.close);
        return db;
      }),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.method == 'GET') {
              final body = request.url.path.endsWith('/voice/roster')
                  ? {'participants': <Object>[]}
                  : <Object>[];
              return http.Response(
                jsonEncode(body),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              jsonEncode({'error': 'boom'}),
              500,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
}

Widget _channelRow() => Scaffold(
  body: ChannelCategorySections(
    channels: [_channel('c1', 'general')],
    categories: const [],
    selectedId: null,
    onReorder: (_) {},
  ),
);

Widget _dmRow() => Scaffold(
  body: DmRow(channel: _channel('d1', 'Priya', dmPeer: 'p1'), selected: false),
);

Future<void> _failEntry(
  WidgetTester tester,
  Widget row,
  Finder target,
  String label,
) async {
  final container = _container();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: row,
      ),
    ),
  );
  await tester.pump();
  await tester.tapAt(
    tester.getCenter(target),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final rows = {
    'channel row': (_channelRow, find.text('general'), 'Mute channel'),
    'dm row': (_dmRow, find.byType(DmRow), 'Mute'),
  };
  for (final MapEntry(key: name, value: (build, target, mute))
      in rows.entries) {
    for (final label in [mute, 'Notify me off hours', 'Mark as unread']) {
      testWidgets('a failed "$label" on a $name is said and throws nothing', (
        tester,
      ) async {
        await _failEntry(tester, build(), target, label);

        final thrown = tester.takeException();
        expect(thrown, isNull, reason: 'uncaught async error: $thrown');
        expect(find.textContaining('Could not'), findsOneWidget);
      });
    }
  }
}
