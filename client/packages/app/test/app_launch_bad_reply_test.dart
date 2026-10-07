// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An app launch that gets an unreadable reply ends refused, never a spinner.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/app_launches.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container(http.Response Function(http.Request) handler) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async => handler(request)),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  for (final body in ['{}', '[]', '']) {
    test('a 200 with body "$body" must settle the launch as refused', () async {
      final container = _container((r) => http.Response(body, 200));
      const surface = AppSurface(moduleId: 'm', command: 'open');
      Object? escaped;
      try {
        await container
            .read(appLaunchesProvider.notifier)
            .launch('msg-1', surface);
      } catch (e) {
        escaped = e;
      }
      final launch = container.read(appLaunchesProvider)['msg-1']!;
      expect(escaped, isNull);
      expect(launch.running, isFalse, reason: 'spinner never resolves');
      expect(launch.error, isNotNull);
    });
  }

  test(
    'and the second launch call returns early, so nothing can recover it',
    () async {
      final container = _container((r) => http.Response('{}', 200));
      const surface = AppSurface(moduleId: 'm', command: 'open');
      final n = container.read(appLaunchesProvider.notifier);
      try {
        await n.launch('msg-1', surface);
      } catch (_) {}
      await n.launch('msg-1', surface, retry: true);
      final launch = container.read(appLaunchesProvider)['msg-1']!;
      expect(launch.running, isFalse);
    },
  );

  test('an unexpected error settles the launch and allows a retry', () async {
    var failing = true;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          if (failing) throw StateError('no client');
          return SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient(
              (request) async => http.Response(
                '{"ok":true,"output":"hi"}',
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    const surface = AppSurface(moduleId: 'm', command: 'open');
    final n = container.read(appLaunchesProvider.notifier);

    await n.launch('msg-1', surface);
    final first = container.read(appLaunchesProvider)['msg-1']!;
    expect(first.running, isFalse);
    expect(first.error, isNotNull);

    failing = false;
    container.invalidate(apiProvider);
    await n.launch('msg-1', surface, retry: true);
    expect(container.read(appLaunchesProvider)['msg-1']!.error, isNull);
  });
}
