// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The preview choice lives on the account: the controller shows what the
/// server holds, saves an explicit toggle to it, and keeps an unsent choice
/// as pending only while the server could not take it.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_app/src/providers/push_content_preview_settings.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container(http.Client client) {
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: client,
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
}

MockClient _server({required bool value, List<bool>? saved}) =>
    MockClient((request) async {
      if (request.url.path != '/push/preview') {
        return http.Response('', 404);
      }
      if (request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        saved?.add(body['include_content'] as bool);
        return http.Response(request.body, 200);
      }
      return http.Response(jsonEncode({'include_content': value}), 200);
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('shows the account value the server holds, unknown until it '
      'answers', () async {
    final container = _container(_server(value: true));
    addTearDown(container.dispose);

    expect(container.read(pushContentPreviewSettingsProvider), isNull);
    await container.read(pushContentPreviewSettingsProvider.notifier).refresh();
    expect(container.read(pushContentPreviewSettingsProvider), isTrue);
  });

  test('a fresh install has no pending choice, so it sends none', () async {
    final container = _container(_server(value: true));
    addTearDown(container.dispose);

    final pending = await container
        .read(pushContentPreviewSettingsProvider.notifier)
        .pendingChoice();
    expect(pending, isNull);
  });

  test('toggling saves the explicit choice to the account and leaves '
      'nothing pending', () async {
    final saved = <bool>[];
    final container = _container(_server(value: true, saved: saved));
    addTearDown(container.dispose);

    final controller = container.read(
      pushContentPreviewSettingsProvider.notifier,
    );
    await controller.setEnabled(false);

    expect(saved, [false]);
    expect(container.read(pushContentPreviewSettingsProvider), isFalse);
    expect(await controller.pendingChoice(), isNull);
  });

  test('a choice the server could not take stays pending for the next '
      'registration', () async {
    final container = _container(
      MockClient((request) async => http.Response('', 503)),
    );
    addTearDown(container.dispose);

    final controller = container.read(
      pushContentPreviewSettingsProvider.notifier,
    );
    await controller.setEnabled(false);

    expect(container.read(pushContentPreviewSettingsProvider), isFalse);
    expect(await controller.pendingChoice(), isFalse);
  });

  test('a failed local-storage read answers no pending choice and is '
      'retried rather than pinned', () async {
    SharedPreferences.setMockInitialValues({
      pushIncludeContentKeyFor('user-1'): true,
    });
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        preferencesProvider.overrideWith((ref) async {
          if (reads++ == 0) throw StateError('storage not readable yet');
          return SharedPreferences.getInstance();
        }),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(
      pushContentPreviewSettingsProvider.notifier,
    );
    expect(await controller.pendingChoice(), isNull);
    expect(await controller.pendingChoice(), isTrue);
  });
}
