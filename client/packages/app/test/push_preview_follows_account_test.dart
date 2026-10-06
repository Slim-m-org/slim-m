// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
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

TokenPair _tokens(String id) => TokenPair(
  userId: id,
  accessToken: 'access-$id',
  refreshToken: 'refresh-$id',
  accessExpiresAt: 0,
);

class _Rig {
  _Rig(this.container, this.session, this.registrations);
  final ProviderContainer container;
  final SessionStore session;
  final List<Map<String, dynamic>> registrations;
}

_Rig _rig({required Map<String, bool> serverValue, bool putFails = false}) {
  SharedPreferences.setMockInitialValues({});
  _mock((call) async => call.method == 'getToken' ? 'abcd1234' : null);
  addTearDown(() => _mock(null));
  final session = SessionStore(tokens: _tokens('a'));
  final registrations = <Map<String, dynamic>>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(session),
      apnsTokenChannelProvider.overrideWithValue(ApnsTokenChannel(isIOS: true)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            final user = session.tokens?.userId ?? 'none';
            if (request.method == 'PUT' && request.url.path == '/push') {
              registrations.add(
                jsonDecode(request.body) as Map<String, dynamic>,
              );
              return http.Response('', 204);
            }
            if (request.url.path == '/push/preview') {
              if (request.method == 'PUT') {
                return putFails
                    ? http.Response('down', 503)
                    : http.Response(request.body, 200);
              }
              return http.Response(
                jsonEncode({'include_content': serverValue[user]}),
                200,
              );
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  return _Rig(container, session, registrations);
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the toggle shows the account that is signed in now', () async {
    final rig = _rig(serverValue: {'a': true, 'b': false});
    final sub = rig.container.listen(
      pushContentPreviewSettingsProvider,
      (_, __) {},
    );
    addTearDown(sub.close);
    await _settle();
    expect(rig.container.read(pushContentPreviewSettingsProvider), isTrue);

    rig.session.clear();
    await _settle();
    rig.session.set(_tokens('b'));
    await _settle();

    expect(
      rig.container.read(pushContentPreviewSettingsProvider),
      isFalse,
      reason: 'B stores include_content=false; the toggle still shows A\'s',
    );
  });

  test('a choice A left pending is not sent in B\'s registration', () async {
    final rig = _rig(serverValue: {'a': false, 'b': false}, putFails: true);
    final push = rig.container.read(pushControllerProvider.notifier);
    await push.register();
    // A turns previews on while the server is unreachable: stays pending.
    await rig.container
        .read(pushContentPreviewSettingsProvider.notifier)
        .setEnabled(true);
    rig.registrations.clear();

    rig.session.clear();
    await _settle();
    rig.session.set(_tokens('b'));
    await _settle();
    await push.register();

    expect(rig.registrations, isNotEmpty);
    expect(
      rig.registrations.every((r) => !r.containsKey('include_content')),
      isTrue,
      reason:
          'B never chose anything; registrations were '
          '${rig.registrations}',
    );
  });
}
