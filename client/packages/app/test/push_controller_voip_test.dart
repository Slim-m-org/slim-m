// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The PushKit VoIP token's path to the server: read at registration, and sent
/// again when PushKit issues it after registration already ran.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_platform/platform.dart';

const _channelName = 'top.npcserver.slimm/push';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void _mock(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), handler);
}

Future<void> _nativeSends(String method, Object? argument) {
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channelName,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, argument),
        ),
        (_) {},
      );
}

ProviderContainer _container(List<Map<String, dynamic>> registrations) {
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path == '/push' && request.method == 'PUT') {
              registrations.add(
                jsonDecode(request.body) as Map<String, dynamic>,
              );
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
      apnsTokenChannelProvider.overrideWithValue(ApnsTokenChannel(isIOS: true)),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the cached VoIP token rides the registration', () async {
    _mock(
      (call) async => switch (call.method) {
        'getToken' => 'abcd1234',
        'getVoipToken' => 'beef0001',
        _ => null,
      },
    );
    addTearDown(() => _mock(null));
    final registrations = <Map<String, dynamic>>[];
    final container = _container(registrations);
    addTearDown(container.dispose);

    await container.read(pushControllerProvider.notifier).register();

    expect(registrations.last['push_token'], 'abcd1234');
    expect(registrations.last['voip_push_token'], 'beef0001');
  });

  test(
    'a VoIP token that lands after registering is sent afterwards',
    () async {
      String? voip;
      _mock(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          'getVoipToken' => voip,
          _ => null,
        },
      );
      addTearDown(() => _mock(null));
      final registrations = <Map<String, dynamic>>[];
      final container = _container(registrations);
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();
      expect(registrations.last['voip_push_token'], isNull);

      voip = 'beef0002';
      await _nativeSends('onVoipToken', 'beef0002');
      await pumpEventQueue();

      expect(registrations.last['voip_push_token'], 'beef0002');
    },
  );
}
