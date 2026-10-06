// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A relaunched signed-in session re-probes `/version` and stops on a key
/// that contradicts the pin, the way an explicit sign-in does.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/server_identity_change_gate.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _server = 'https://chat.example';
const _handle = 'server_identity:$_server';
const _keyA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _keyB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

Map<String, dynamic> _identity(String key) => {
  'public_key': key,
  'fingerprint': 'deadbeefcafebabefeedface1337d00d',
  'fingerprint_groups': [
    'dead',
    'beef',
    'cafe',
    'babe',
    'feed',
    'face',
    '1337',
    'd00d',
  ],
  'color_strip': [0, 1, 2, 3],
};

class _NoopSync extends SyncController {
  _NoopSync(super.ref);

  @override
  Future<void> start() async {}

  void flip(SyncStatus next) => state = next;
}

bool probeFails = false;

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required KeyStore keyStore,
  required String presentedKey,
  bool signedIn = true,
}) async {
  final client = MockClient((request) async {
    if (request.url.path == '/version') {
      if (probeFails) throw http.ClientException('network down');
      return http.Response(
        jsonEncode({
          'name': 'slim-m',
          'version': '1.0.0',
          'protocol': 1,
          'identity': _identity(presentedKey),
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 200);
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keyStore),
      syncControllerProvider.overrideWith(_NoopSync.new),
      serverUrlProvider.overrideWith((ref) => Uri.parse(_server)),
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
  if (signedIn) container.read(sessionProvider).set(_tokens);

  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const ServerIdentityChangeGate(child: Text('the app')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('a key that contradicts the pin stops the app', (tester) async {
    final store = InMemoryKeyStore();
    await store.put(_handle, _keyA);
    await _pump(tester, keyStore: store, presentedKey: _keyB);

    expect(find.text('the app'), findsNothing);
    expect(find.text("This server's identity changed"), findsOneWidget);
  });

  testWidgets('a matching pin, or none yet, leaves the app alone', (
    tester,
  ) async {
    final matching = InMemoryKeyStore();
    await matching.put(_handle, _keyA);
    await _pump(tester, keyStore: matching, presentedKey: _keyA);
    expect(find.text('the app'), findsOneWidget);

    await _pump(tester, keyStore: InMemoryKeyStore(), presentedKey: _keyB);
    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('trusting the new key re-pins it and resumes the app', (
    tester,
  ) async {
    final store = InMemoryKeyStore();
    await store.put(_handle, _keyA);
    await _pump(tester, keyStore: store, presentedKey: _keyB);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Trust the new identity'));
    await tester.pumpAndSettle();

    expect(await store.read(_handle), _keyB);
    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('cancelling signs the session out', (tester) async {
    final store = InMemoryKeyStore();
    await store.put(_handle, _keyA);
    final container = await _pump(tester, keyStore: store, presentedKey: _keyB);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(container.read(sessionProvider).isSignedIn, isFalse);
    expect(await store.read(_handle), _keyA);
  });

  testWidgets('a shown mismatch survives a failed re-probe', (tester) async {
    probeFails = false;
    addTearDown(() => probeFails = false);
    final store = InMemoryKeyStore();
    await store.put(_handle, _keyA);
    final container = await _pump(tester, keyStore: store, presentedKey: _keyB);
    expect(find.text("This server's identity changed"), findsOneWidget);

    probeFails = true;
    (container.read(syncControllerProvider.notifier) as _NoopSync).flip(
      SyncStatus.live,
    );
    await tester.pumpAndSettle();

    expect(find.text("This server's identity changed"), findsOneWidget);
    expect(find.text('the app'), findsNothing);
  });
}
