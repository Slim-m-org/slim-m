// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A permissions fetch that failed in passing is asked again, not read as no rights for the session.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

http.Response _answer(int status) => status == 200
    ? http.Response(
        jsonEncode({'permissions': 64}),
        200,
        headers: {'content-type': 'application/json'},
      )
    : http.Response('', status);

ProviderContainer _container(List<int> statuses, List<String> asked) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        asked.add(request.url.path);
        return _answer(
          statuses.length > 1 ? statuses.removeAt(0) : statuses[0],
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

const _tokens = api.TokenPair(
  userId: 'u',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

void main() {
  late Duration before;
  setUp(() {
    before = channelPermissionsRetryDelay;
    channelPermissionsRetryDelay = const Duration(milliseconds: 20);
  });
  tearDown(() => channelPermissionsRetryDelay = before);

  test('a transient failure is retried and the rights come back', () async {
    final asked = <String>[];
    final container = _container([503, 200], asked);
    container.listen(myChannelPermissionsProvider('c1'), (_, _) {});

    expect(container.read(myChannelPermissionsProvider('c1')), 0);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(asked.length, 2);
    expect(container.read(myChannelPermissionsProvider('c1')), 64);
  });

  test('a refusal is the answer and is not asked again', () async {
    final asked = <String>[];
    final container = _container([403], asked);
    container.listen(myChannelPermissionsProvider('c1'), (_, _) {});

    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(asked.length, 1);
    expect(container.read(myChannelPermissionsProvider('c1')), 0);
  });
}
