// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock catalog's three independent reads start together, so opening the
/// screen costs one round trip rather than three in a row.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

ProviderContainer _container({
  required List<String> started,
  required Future<void> gate,
  bool sourcesFail = false,
}) {
  final session = SessionStore(
    tokens: const TokenPair(
      userId: 'u',
      accessToken: 'a',
      refreshToken: 'r',
      accessExpiresAt: 0,
    ),
  );
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(session),
      apiProvider.overrideWith(
        (ref) => SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: session,
          httpClient: MockClient((request) async {
            started.add(request.url.path);
            await gate;
            if (sourcesFail && request.url.path == '/space/dock/sources') {
              return http.Response('boom', 500);
            }
            return http.Response(jsonEncode([]), 200);
          }),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('modules, installed and sources are requested together', () async {
    final started = <String>[];
    final gate = Completer<void>();
    final container = _container(started: started, gate: gate.future);
    final sub = container.listen(dockCatalogProvider, (_, _) {});
    addTearDown(sub.close);

    await Future<void>.delayed(Duration.zero);
    expect(started.toSet(), {
      '/space/dock/modules',
      '/space/dock/installed',
      '/space/dock/sources',
    }, reason: 'each read waited for the one before it');

    gate.complete();
    final catalog = await container.read(dockCatalogProvider.future);
    expect(catalog.sourcesFailed, isFalse);
  });

  test('a failing sources read still loads the rest of the catalog', () async {
    final started = <String>[];
    final container = _container(
      started: started,
      gate: Future<void>.value(),
      sourcesFail: true,
    );
    final catalog = await container.read(dockCatalogProvider.future);
    expect(catalog.sourcesFailed, isTrue);
  });
}
