// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A send that could not reach the server keeps its author's name with no
/// profile loaded, and says it is sent again on reconnect, which it is.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';
import 'package:slimm_app/src/features/messages/widgets/author_label.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

class _Me extends EffectiveMe {
  @override
  api.Me? build() => const api.Me(
    id: 'bob',
    username: 'bob',
    displayName: 'Bob Ross',
    createdAt: 0,
    permissions: 0,
  );
}

Future<Message> _failedSend([
  Future<http.Response> Function(http.Request)? answer,
]) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWith((ref) async => MessageStore(db)),
      effectiveMeProvider.overrideWith(_Me.new),
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
          httpClient: MockClient(
            answer ?? (request) async => throw http.ClientException('offline'),
          ),
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
  final store = await container.read(storeProvider.future);
  return (await store.failedMessages()).single;
}

void main() {
  test('your unsent message shows your name while no profile loads', () async {
    final failed = await _failedSend();
    expect(
      authorLabel(
        authorId: failed.authorId,
        cachedDisplayName: failed.authorDisplayName,
        profiles: const {},
      ),
      'Bob Ross',
    );
  });

  test('an unreachable server says the message is sent on reconnect', () async {
    final failed = await _failedSend();
    expect(failed.failureReason, contains('when you reconnect'));
    expect(failed.failureReason, isNot(contains('Nothing was changed')));
  });

  test('a proxy page, with the live connection still up, points to Retry '
      'rather than promising a resend', () async {
    final failed = await _failedSend(
      (request) async => http.Response(
        '<html>502 Bad Gateway</html>',
        200,
        headers: {'content-type': 'text/html'},
      ),
    );
    expect(
      failed.failureReason,
      'Could not reach the server. Retry, or it is sent again when you '
      'reconnect.',
    );
  });
}
