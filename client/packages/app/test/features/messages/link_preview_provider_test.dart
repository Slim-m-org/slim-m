// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `linkPreviewProvider` must no-op - no request at all - on a deployment
/// that has not enabled link previews, the same "no button, no request"
/// contract `Version.gifSearchEnabled` gets from the GIF picker.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart'
    show serverInfoProvider;

const _tokens = TokenPair(
  userId: 'u1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

ProviderContainer _containerWith({
  required bool? linkPreviewsEnabled,
  required int Function() onFetch,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      serverInfoProvider.overrideWith(
        (ref) => Future.value(
          Version(
            name: 'slim-m',
            version: '0.30.0',
            protocol: 1,
            linkPreviewsEnabled: linkPreviewsEnabled,
          ),
        ),
      ),
      apiProvider.overrideWith((ref) {
        return testApi((request) async {
          onFetch();
          return http.Response(
            jsonEncode({
              'url': 'https://example.com',
              'title': 'An example',
              'description': null,
              'site_name': null,
              'image_token': null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }, session: ref.watch(sessionProvider));
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('an enabled deployment fetches and returns the preview', () async {
    var fetches = 0;
    final container = _containerWith(
      linkPreviewsEnabled: true,
      onFetch: () => fetches += 1,
    );

    // Held open the way avatar_cache_test.dart holds avatarBytesProvider: an unwatched autoDispose provider can be torn down mid-flight.
    container.listen(linkPreviewProvider('https://example.com'), (_, _) {});
    final preview = await container.read(
      linkPreviewProvider('https://example.com').future,
    );

    expect(preview?.title, 'An example');
    expect(fetches, 1);
  });

  test(
    'a deployment that has not enabled link previews makes no request',
    () async {
      var fetches = 0;
      final container = _containerWith(
        linkPreviewsEnabled: false,
        onFetch: () => fetches += 1,
      );

      container.listen(linkPreviewProvider('https://example.com'), (_, _) {});
      final preview = await container.read(
        linkPreviewProvider('https://example.com').future,
      );

      expect(preview, isNull);
      expect(fetches, 0);
    },
  );

  test(
    'a server too old to report the capability is treated as disabled',
    () async {
      var fetches = 0;
      final container = _containerWith(
        linkPreviewsEnabled: null,
        onFetch: () => fetches += 1,
      );

      container.listen(linkPreviewProvider('https://example.com'), (_, _) {});
      final preview = await container.read(
        linkPreviewProvider('https://example.com').future,
      );

      expect(preview, isNull);
      expect(fetches, 0);
    },
  );
}
