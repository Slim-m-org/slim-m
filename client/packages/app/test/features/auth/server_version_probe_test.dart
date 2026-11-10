// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The client floor and the identity recheck share one `/version` read, and
/// only the sync reaching live asks for a new one.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/providers/client_floor.dart';
import 'package:slimm_app/src/features/auth/providers/server_identity_recheck.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_sync.dart';

const _server = 'https://chat.example';
const _handle = 'server_identity:$_server';
const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

class _Harness {
  _Harness(this.container, this.sync);

  final ProviderContainer container;
  final NoopSyncController sync;
  int versionReads = 0;

  Future<void> settle() async {
    await pumpEventQueue();
    await container.read(clientFloorProvider.future);
    await container.read(serverIdentityChangeProvider.future);
  }
}

Future<_Harness> _harness({bool failProbe = false}) async {
  final store = InMemoryKeyStore();
  await store.put(_handle, _key);
  late _Harness harness;
  final client = MockClient((request) async {
    if (request.url.path != '/version') return http.Response('{}', 200);
    harness.versionReads++;
    if (failProbe) throw http.ClientException('network down');
    return http.Response(
      jsonEncode({
        'name': 'slim-m',
        'version': '1.0.0',
        'protocol': 1,
        'identity': {
          'public_key': _key,
          'fingerprint': 'deadbeefcafebabefeedface1337d00d',
          'fingerprint_groups': ['dead', 'beef', 'cafe', 'babe'],
          'color_strip': [0, 1, 2, 3],
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(store),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      serverUrlProvider.overrideWith((ref) => Uri.parse(_server)),
      appInfoProvider.overrideWith(
        (ref) => PackageInfo(
          appName: 'slim-m',
          packageName: 'top.npcserver.slimm',
          version: '1.0.0',
          buildNumber: '1',
        ),
      ),
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
  container.read(sessionProvider).set(_tokens);
  container.listen(clientFloorProvider, (_, _) {});
  container.listen(serverIdentityChangeProvider, (_, _) {});
  harness = _Harness(
    container,
    container.read(syncControllerProvider.notifier) as NoopSyncController,
  );
  return harness;
}

void main() {
  test(
    'the floor and the identity recheck read /version once between them',
    () async {
      final harness = await _harness();
      await harness.settle();

      expect(harness.versionReads, 1);
    },
  );

  test('only reaching live asks again, not connecting or offline', () async {
    final harness = await _harness();
    await harness.settle();

    for (final status in [
      SyncStatus.connecting,
      SyncStatus.offline,
      SyncStatus.connecting,
      SyncStatus.offline,
    ]) {
      harness.sync.report(status);
      await harness.settle();
    }
    expect(harness.versionReads, 1, reason: 'an outage must not poll /version');

    harness.sync.report(SyncStatus.connecting);
    harness.sync.report(SyncStatus.live);
    await harness.settle();
    expect(harness.versionReads, 2);
  });

  test(
    'an unreachable server fails open and is not polled during the outage',
    () async {
      final harness = await _harness(failProbe: true);
      await harness.settle();
      final reads = harness.versionReads;

      expect(
        harness.container.read(clientFloorProvider).valueOrNull,
        ClientFloor.unknown,
      );
      expect(
        harness.container.read(serverIdentityChangeProvider).valueOrNull,
        isNull,
      );

      harness.sync.report(SyncStatus.connecting);
      harness.sync.report(SyncStatus.offline);
      await harness.settle();
      expect(harness.versionReads, reads);
    },
  );
}
