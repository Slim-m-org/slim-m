// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a registration carries `include_content`, split out of
/// `push_controller_test.dart` to keep that file at its allowlisted size
/// (`scripts/file-budget-allow.txt`) rather than growing it further.
///
/// Fixtures are a small, deliberate duplicate of that file's own
/// `_container`/`_mock`/`_tokens` rather than a shared import: Dart privacy
/// is per-file, so a leading-underscore helper in one test file is not
/// reachable from a sibling, the same constraint CLAUDE.md already records
/// for cross-package test fixtures.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_content_preview_settings.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_platform/platform.dart';

const _channelName = 'top.npcserver.slimm/push';

void _mock(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), handler);
}

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container({
  required http.Client httpClient,
  SessionStore? session,
  ApnsTokenChannel? channel,
  List<Override> extra = const [],
}) {
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      if (session != null) sessionProvider.overrideWithValue(session),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: httpClient,
        );
        ref.onDispose(api.close);
        return api;
      }),
      if (channel != null) apnsTokenChannelProvider.overrideWithValue(channel),
      ...extra,
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('push content preview', () {
    Future<List<Map<String, dynamic>>> registerOnce({
      Map<String, Object> prefs = const {},
      List<Override> extra = const [],
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final requests = <Map<String, dynamic>>[];
      _mock((call) async => call.method == 'getToken' ? 'abcd1234' : null);
      addTearDown(() => _mock(null));
      final container = _container(
        session: SessionStore(tokens: _tokens),
        httpClient: MockClient((request) async {
          if (request.method == 'PUT' && request.url.path == '/push') {
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          }
          if (request.url.path == '/push/preview') {
            return http.Response('{"include_content":true}', 200);
          }
          return http.Response('', 204);
        }),
        channel: ApnsTokenChannel(isIOS: true),
        extra: extra,
      );
      addTearDown(container.dispose);
      await container.read(pushControllerProvider.notifier).register();
      await container.read(pushControllerProvider.notifier).register();
      return requests;
    }

    test('a device that never toggled sends no include_content, so a '
        'reinstall cannot reset the account choice', () async {
      final requests = await registerOnce();

      expect(requests, hasLength(2));
      expect(
        requests.every(
          (r) =>
              !r.containsKey('include_content') &&
              !r.containsKey('include_content_chosen'),
        ),
        isTrue,
      );
    });

    test('an explicit choice not yet accepted is sent once, then not '
        'again', () async {
      final requests = await registerOnce(
        prefs: {pushIncludeContentKeyFor('user-1'): false},
      );

      expect(requests[0]['include_content'], isFalse);
      expect(requests[0]['include_content_chosen'], isTrue);
      expect(requests[1].containsKey('include_content'), isFalse);
      expect(requests[1].containsKey('include_content_chosen'), isFalse);
    });

    test('a preferences read that fails once still sends the pending '
        'choice on a later registration', () async {
      var reads = 0;
      final requests = await registerOnce(
        prefs: {pushIncludeContentKeyFor('user-1'): true},
        extra: [
          preferencesProvider.overrideWith((ref) async {
            if (reads++ == 0) throw StateError('storage not readable yet');
            return SharedPreferences.getInstance();
          }),
        ],
      );

      expect(requests[0].containsKey('include_content'), isFalse);
      expect(requests[1]['include_content'], isTrue);
    });
  });
}
