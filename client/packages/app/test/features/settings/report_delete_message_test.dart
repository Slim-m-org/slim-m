// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reported message deleted on the server counts as deleted even when the
/// local row cannot be dropped, so the report closes instead of showing a failure.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/screens/admin/report_card_actions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

void main() {
  test('a failing local discard does not fail a server-side delete', () async {
    final deletes = <String>[];
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          SessionStore(
            tokens: const TokenPair(
              userId: 'mod',
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 0,
            ),
          ),
        ),
        storeProvider.overrideWith((ref) async => throw StateError('no db')),
        mockApiOverride((request) async {
          deletes.add('${request.method} ${request.url.path}');
          return http.Response('', 204);
        }),
      ],
    );
    addTearDown(container.dispose);

    await deleteMessageEverywhere(container, 'channel-1', 'message-1');

    expect(deletes, ['DELETE /channels/channel-1/messages/message-1']);
  });
}
