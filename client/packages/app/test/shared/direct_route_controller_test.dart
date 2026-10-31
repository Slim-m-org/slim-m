// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The LAN shortcut is asked for after sign-in, and a server that cannot answer
/// leaves the app on the public route instead of failing.
library;

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_api/src/direct_route.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/providers/direct_route_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container(
  http.Response Function(http.Request) answer,
  List<String> asked,
) {
  return ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('https://slimm.test'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            asked.add('${request.method} ${request.url.path}');
            return answer(request);
          }),
        ),
      ),
    ],
  );
}

void main() {
  test('reading the provider asks the signed-in route', () async {
    final asked = <String>[];
    final container = _container(
      (_) => http.Response(
        '{"addresses":[]}',
        200,
        headers: {'content-type': 'application/json'},
      ),
      asked,
    );
    addTearDown(container.dispose);

    await container.read(directRouteProvider.future);

    expect(asked, ['GET /direct-route']);
  });

  test('a server that refuses leaves the app on the public route', () async {
    final asked = <String>[];
    final container = _container(
      (_) => http.Response(
        '{"error":"not found"}',
        404,
        headers: {'content-type': 'application/json'},
      ),
      asked,
    );
    addTearDown(container.dispose);

    await container.read(directRouteProvider.future);

    expect(asked, ['GET /direct-route']);
  });

  test('resuming the app drops pooled LAN connections', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final route = _CountingRoute();
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mobileLifecycleHostProvider.overrideWithValue(true),
        apiProvider.overrideWith(
          (ref) => api.SlimmApi(
            baseUrl: Uri.parse('https://slimm.test'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((_) async => http.Response('{}', 404)),
            directRoute: route,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(directRouteProvider.future);

    final lifecycle = container.read(appLifecycleProvider.notifier);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(route.invalidated, 0);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(route.invalidated, 1);
  });
}

class _CountingRoute implements DirectRoute {
  int invalidated = 0;

  @override
  void invalidate() => invalidated++;

  @override
  bool get active => false;

  @override
  bool get hasAddresses => false;

  @override
  Stream<bool> get activeChanges => const Stream<bool>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
