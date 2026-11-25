// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call answered on the lock screen at launch belongs to the account whose
/// server holds the ring, not to whichever account was last on screen.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/voice/providers/dm_call.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../accounts/account_host_harness.dart';

const _channelName = 'top.npcserver.slimm/callkit_incoming';

AccountHarness _harness({required bool ringOnSecond}) {
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, __) => throw 0)],
  );
  return AccountHarness(
    extraOverrides: [
      routerProvider.overrideWithValue(router),
      callKitIncomingChannelProvider.overrideWith(
        (ref) => CallKitIncomingChannel(enabled: true),
      ),
      apiProvider.overrideWith((ref) {
        final onSecond = ref.read(serverUrlProvider).host.startsWith('second');
        final rings = onSecond && ringOnSecond
            ? [
                {
                  'channel_id': 'dm-1',
                  'ring_id': 'ring-1',
                  'caller_id': 'caller-1',
                  'remaining_ms': 20000,
                },
              ]
            : <Map<String, Object>>[];
        final client = testApi((request) async {
          if (request.url.path != '/voice/rings/incoming') {
            return http.Response('', 500);
          }
          return http.Response(
            jsonEncode({'rings': rings}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }, session: ref.read(sessionProvider));
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
}

Future<(AccountHarness, List<String>)> _launch({
  required bool ringOnSecond,
}) async {
  final ended = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), (
        call,
      ) async {
        if (call.method == 'endCall') {
          ended.add((call.arguments as Map)['id'] as String);
        }
        return call.method == 'takePending'
            ? [
                {'event': 'ringing', 'id': 'uuid-1'},
                {'event': 'answered', 'id': 'uuid-1'},
              ]
            : null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null),
  );
  final h = _harness(ringOnSecond: ringOnSecond);
  addTearDown(h.dispose);
  await h.seed('https://first.example', user: 'u1', active: true);
  await h.seed('https://second.example', user: 'u2');
  h.host.createFirst();
  await h.host.start();
  await pumpEventQueueTimes(40);
  h.host.active!.container.read(dmCallRingControllerProvider);
  await pumpEventQueueTimes(40);
  return (h, ended);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a ring held by another account is answered there', () async {
    final (h, ended) = await _launch(ringOnSecond: true);

    final second = h.host.runtimeFor('https://second.example')!.container;
    expect(second.read(dmCallOpenProvider), 'dm-1');
    expect(h.host.active?.account?.origin, 'https://second.example');
    expect(ended, isEmpty, reason: 'the call is live, not over');
  });

  test('no account holding the ring ends the system call', () async {
    final (h, ended) = await _launch(ringOnSecond: false);

    final second = h.host.runtimeFor('https://second.example')!.container;
    expect(second.read(dmCallOpenProvider), isNull);
    expect(ended, ['uuid-1']);
  });
}
