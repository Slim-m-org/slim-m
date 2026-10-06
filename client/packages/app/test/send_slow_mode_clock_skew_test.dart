// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The slow-mode countdown runs on this device's clock, so a send is recorded
/// at the device's own time, not the server's `created_at`: a device clock
/// behind the server would otherwise see the send as still in the future and
/// pin the countdown at the full interval.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_actions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/slow_mode_controller.dart';
import 'package:slimm_data/data.dart';

Future<DateTime?> _recordedAfterSend({required int serverCreatedAt}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWith((ref) async => MessageStore(db)),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost'),
          session: api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'bob',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 99999999999999,
            ),
          ),
          httpClient: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': body['id'],
                'channel_id': 'c1',
                'author_id': 'bob',
                'author_display_name': 'Bob',
                'seq': 1,
                'content': body['content'],
                'created_at': serverCreatedAt,
                'edited_at': null,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await sendOptimistically(
    container.read,
    id: 'm1',
    channelId: 'c1',
    authorId: 'bob',
    content: 'hi',
  );
  return container.read(slowModeLastSentProvider)['c1'];
}

void main() {
  test('a server clock ahead of the device does not push the send into the '
      'future', () async {
    final ahead = DateTime.now().add(const Duration(minutes: 5));

    final recorded = await _recordedAfterSend(
      serverCreatedAt: ahead.millisecondsSinceEpoch,
    );

    expect(
      recorded!.isAfter(DateTime.now().add(const Duration(seconds: 5))),
      isFalse,
    );
  });

  test(
    'a server clock behind the device does not shorten the countdown',
    () async {
      final behind = DateTime.now().subtract(const Duration(minutes: 5));

      final recorded = await _recordedAfterSend(
        serverCreatedAt: behind.millisecondsSinceEpoch,
      );

      expect(
        recorded!.isBefore(DateTime.now().subtract(const Duration(seconds: 5))),
        isFalse,
      );
    },
  );
}
