// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_api/api.dart' show SessionStore;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/screens/channel_read_marker.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Advances to seq 5 twice. The second call passes [secondLastReadSeq] as the
/// local marker, which the first call's own store write has already moved to 5.
Future<int> _putsAfterTwoAdvances(
  WidgetTester tester,
  int firstStatus, {
  int secondLastReadSeq = 5,
  Duration retryAfter = Duration.zero,
}) async {
  var puts = 0;
  late ReadMarker marker;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          if (request.method == 'PUT') {
            puts++;
            if (puts == 1 && firstStatus != 200) {
              return http.Response('{}', firstStatus);
            }
            return http.Response(
              '{"last_read_seq": 5, "unread": 0, "manually_unread": false}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200);
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
            marker = ReadMarker(ref, retryAfter: retryAfter);
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    marker.advance('c1', seq: 5, lastReadSeq: 0, manuallyUnread: false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    marker.advance(
      'c1',
      seq: 5,
      lastReadSeq: secondLastReadSeq,
      manuallyUnread: false,
    );
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

  testWidgets('a marker the server already has is not sent again', (
    tester,
  ) async {
    expect(await _putsAfterTwoAdvances(tester, 200), 1);
  });

  testWidgets('a failed markRead waits before it is retried', (tester) async {
    expect(
      await _putsAfterTwoAdvances(
        tester,
        503,
        retryAfter: const Duration(minutes: 1),
      ),
      1,
      reason: 'every rebuild while offline would otherwise send a request',
    );
  });
}
