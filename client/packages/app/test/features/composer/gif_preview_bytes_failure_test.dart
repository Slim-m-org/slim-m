// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A thumbnail whose fetch failed is not kept, so the next view asks again.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/providers/gif_preview_bytes.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'u',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

void main() {
  test('a failed preview fetch is asked for again on the next view', () async {
    var fetches = 0;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          fetches++;
          return fetches == 1
              ? http.Response('', 503)
              : http.Response('gif', 200);
        }),
      ],
    );
    addTearDown(container.dispose);
    const key = (gifId: 'tok-1', channelId: 'c1');

    final first = container.listen(gifPreviewBytesProvider(key), (_, _) {});
    await expectLater(
      container.read(gifPreviewBytesProvider(key).future),
      throwsA(isA<api.ApiException>()),
    );
    first.close();
    await Future<void>.delayed(Duration.zero);

    final bytes = await container.read(gifPreviewBytesProvider(key).future);

    expect(fetches, 2);
    expect(bytes, isNotEmpty);
  });
}
