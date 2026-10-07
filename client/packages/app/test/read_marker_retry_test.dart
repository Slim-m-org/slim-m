// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_api/api.dart' show SessionStore;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/channel_read_marker.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<int> _putsAfterTwoAdvances(WidgetTester tester, int firstStatus) async {
  var puts = 0;
  late ReadMarker marker;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final a = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.method == 'PUT') {
                puts++;
                if (puts == 1) return http.Response('{}', firstStatus);
                return http.Response(
                  '{"last_read_seq": 5, "manually_unread": false}',
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response('{}', 200);
            }),
          );
          ref.onDispose(a.close);
          return a;
        }),
        storeProvider.overrideWith((ref) async {
          final db = SlimmDatabase(NativeDatabase.memory());
          ref.onDispose(db.close);
          return MessageStore(db);
        }),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            marker = ReadMarker(ref);
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    marker.advance('c1', seq: 5, lastReadSeq: 0, manuallyUnread: false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    marker.advance('c1', seq: 5, lastReadSeq: 0, manuallyUnread: false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  return puts;
}

void main() {
  testWidgets('a failed markRead is retried on the next advance for that seq', (
    tester,
  ) async {
    expect(
      await _putsAfterTwoAdvances(tester, 503),
      2,
      reason: 'server marker never reached seq 5 after a 503',
    );
  });

  testWidgets('a refused markRead is not retried on every rebuild', (
    tester,
  ) async {
    expect(await _putsAfterTwoAdvances(tester, 403), 1);
  });
}
