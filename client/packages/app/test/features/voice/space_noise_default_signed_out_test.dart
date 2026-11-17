// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A signed-out launch has no Space to ask, so the Space's noise default is
/// never fetched from the placeholder address.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/noise_suppression.dart';
import 'package:slimm_app/src/providers/providers.dart';

void main() {
  test('signed out, the Space noise default is not fetched', () async {
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      return http.Response(
        jsonEncode({
          'name': 'slim-m',
          'version': '0.89.0',
          'protocol': 1,
          'strong_noise_suppression': true,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final fetch = FutureProvider<bool?>(fetchSpaceStrongNoiseSuppression);
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(SessionStore()),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: ref.watch(serverUrlProvider),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(fetch.future), isNull);
    expect(requested, isEmpty);
  });
}
