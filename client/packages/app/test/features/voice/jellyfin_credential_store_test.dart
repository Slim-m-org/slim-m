// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Jellyfin direct-play login belongs to one slim-m account on one media
/// server, and signing that account out removes it from the device.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account_services.dart';
import 'package:slimm_app/src/features/voice/providers/jellyfin_credential_store.dart';
import 'package:slimm_app/src/features/voice/providers/jellyfin_direct_client.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';
import 'voice_controller_harness.dart';

const _login = JellyfinSession(token: 'tok', userId: 'u-jelly');
const _url = 'http://10.0.0.5:8096';

class _NoopPush extends PushController {
  _NoopPush(super.ref);

  @override
  Future<void> register() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('another account on the device does not see the login', () async {
    final keys = InMemoryKeyStore();
    final a = JellyfinCredentialStore(keys);
    await a.save('alice', _url, _login);
    expect((await a.load('alice', _url))?.token, 'tok');
    expect(await a.load('bob', _url), isNull);
    expect(await a.load('alice', 'http://other:8096'), isNull);
  });

  test('forgetting an account removes every server it signed in to', () async {
    final keys = InMemoryKeyStore();
    final store = JellyfinCredentialStore(keys);
    await store.save('alice', _url, _login);
    await store.save('alice', 'http://other:8096', _login);
    await store.save('bob', _url, _login);
    await store.forgetAll('alice');
    expect(await store.load('alice', _url), isNull);
    expect(await store.load('alice', 'http://other:8096'), isNull);
    expect((await store.load('bob', _url))?.token, 'tok');
  });

  test('signing out deletes the account login from the device', () async {
    final keys = InMemoryKeyStore();
    await JellyfinCredentialStore(keys).save('user-1', _url, _login);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(keys),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'user-1',
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 0,
            ),
          ),
        ),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        pushControllerProvider.overrideWith((ref) => _NoopPush(ref)),
        storeProvider.overrideWith((ref) async => throw StateError('n/a')),
        mockApiOverride((_) async => http.Response('', 204)),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: FakeSession()),
        ),
      ],
    );
    addTearDown(container.dispose);

    await signOutVia(container.read);

    expect(await JellyfinCredentialStore(keys).load('user-1', _url), isNull);
  });
}
