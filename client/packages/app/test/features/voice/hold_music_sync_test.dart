// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hold music follows the account: the account's value wins, a device with the
/// only choice uploads it, and a toggle is saved to the account.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/hold_music_sync.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Account {
  _Account(this.value);

  bool? value;
  bool offline = false;
  final puts = <bool>[];

  MockClient get client => MockClient((request) async {
    if (offline) throw http.ClientException('offline');
    if (request.url.path != '/me/hold-music') return http.Response('', 404);
    if (request.method == 'PUT') {
      value = (jsonDecode(request.body) as Map)['enabled'] as bool;
      puts.add(value!);
    }
    return http.Response(
      jsonEncode({'enabled': value}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

ProviderContainer _container(_Account account) => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
    apiProvider.overrideWith((ref) {
      final api = SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: account.client,
      );
      ref.onDispose(api.close);
      return api;
    }),
  ],
);

Future<void> _syncOn(ProviderContainer container) async {
  container.read(voiceSettingsControllerProvider);
  await container.read(preferencesProvider.future);
  await Future<void>.delayed(Duration.zero);
  await syncHoldMusic(container.read);
}

void main() {
  test('the account value wins over this device', () async {
    SharedPreferences.setMockInitialValues({holdMusicEnabledKey: false});
    final account = _Account(true);
    final container = _container(account);
    addTearDown(container.dispose);

    await _syncOn(container);

    expect(
      container.read(voiceSettingsControllerProvider).holdMusicEnabled,
      isTrue,
    );
    expect(account.puts, isEmpty);
  });

  test('with no account value the local choice is uploaded', () async {
    SharedPreferences.setMockInitialValues({holdMusicEnabledKey: true});
    final account = _Account(null);
    final container = _container(account);
    addTearDown(container.dispose);

    await _syncOn(container);

    expect(account.value, isTrue);
  });

  test('with neither, nothing is sent', () async {
    SharedPreferences.setMockInitialValues({});
    final account = _Account(null);
    final container = _container(account);
    addTearDown(container.dispose);

    await _syncOn(container);

    expect(account.puts, isEmpty);
  });

  test('toggling saves to the account', () async {
    SharedPreferences.setMockInitialValues({});
    final account = _Account(null);
    final container = _container(account);
    addTearDown(container.dispose);

    await container
        .read(voiceSettingsControllerProvider.notifier)
        .setHoldMusicEnabled(true);

    expect(account.puts, [true]);
  });

  test(
    'a toggle made offline is uploaded on resume, not overwritten',
    () async {
      SharedPreferences.setMockInitialValues({holdMusicEnabledKey: true});
      final account = _Account(true);
      final container = _container(account);
      addTearDown(container.dispose);
      await _syncOn(container);

      account.offline = true;
      await container
          .read(voiceSettingsControllerProvider.notifier)
          .setHoldMusicEnabled(false);
      account.offline = false;
      await syncHoldMusic(container.read);

      expect(
        container.read(voiceSettingsControllerProvider).holdMusicEnabled,
        isFalse,
      );
      expect(account.value, isFalse);
    },
  );

  test('once uploaded, the account value wins again', () async {
    SharedPreferences.setMockInitialValues({holdMusicEnabledKey: true});
    final account = _Account(true);
    final container = _container(account);
    addTearDown(container.dispose);
    await _syncOn(container);
    account.offline = true;
    await container
        .read(voiceSettingsControllerProvider.notifier)
        .setHoldMusicEnabled(false);
    account.offline = false;
    await syncHoldMusic(container.read);

    account.value = true;
    await syncHoldMusic(container.read);

    expect(
      container.read(voiceSettingsControllerProvider).holdMusicEnabled,
      isTrue,
    );
  });
}
