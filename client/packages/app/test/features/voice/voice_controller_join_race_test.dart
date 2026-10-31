// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel switch mid-join: two `join()` calls overlapping on one
/// controller instance, found while adversarially racing the stage
/// computation `voice_screen.dart` builds on `VoiceState.joining`.
///
/// Before the generation guard in `VoiceController.join`, an abandoned join's
/// eventual outcome - success or failure - wrote straight onto whatever
/// channel the controller's shared `state` currently named, with no check
/// that the call writing it was still the one anybody cared about.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  /// A gated MockClient answering two channels differently: `chan-a`'s token
  /// fetch waits on [gateA] and then fails with a permanent error, `chan-b`'s
  /// succeeds once [gateB] (default already-completed) opens.
  http.Client gatedClient(
    Completer<void> gateA, {
    Completer<void>? gateB,
  }) => MockClient((request) async {
    // Answers a clean leave's forget-heartbeat call, so it never logs past this test's own disposed container.
    if (request.url.path.endsWith('/voice/heartbeat')) {
      return http.Response('', 204);
    }
    if (request.url.path.contains('chan-a')) {
      await gateA.future;
      return http.Response(
        jsonEncode({
          'error': {'code': 'not_configured', 'message': 'no sfu'},
        }),
        501,
        headers: {'content-type': 'application/json'},
      );
    }
    if (gateB != null) await gateB.future;
    return http.Response(
      jsonEncode({
        'url': 'wss://sfu.example.com',
        'room': 'chan-b',
        'token': 'jwt',
        'expires_at': 0,
        'can_publish': true,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  test('an abandoned join failing after a channel switch does not error the '
      'channel switched to', () async {
    final gateA = Completer<void>();
    final controller = harness.controllerWith(
      FakeSession(),
      gatedClient(gateA),
    );

    final joinA = controller.join('chan-a');
    final joinB = controller.join('chan-b');
    await joinB;
    expect(controller.state.channelId, 'chan-b');
    expect(controller.state.error, isNull);

    // chan-a's own belated failure must not reach chan-b's state.
    gateA.complete();
    await joinA;

    expect(controller.state.channelId, 'chan-b');
    expect(controller.state.error, isNull);
    expect(controller.state.state.name, isNot('failed'));
  });

  test(
    'chan-a resolving while chan-b is still joining does not clear joining '
    'out from under chan-b, nor leave a stale error behind once chan-b lands',
    () async {
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      final controller = harness.controllerWith(
        FakeSession(),
        gatedClient(gateA, gateB: gateB),
      );

      final joinA = controller.join('chan-a');
      final joinB = controller.join('chan-b');

      gateA.complete();
      await joinA;
      // chan-b's own join has not answered yet; it must still read as busy.
      expect(controller.state.channelId, 'chan-b');
      expect(controller.state.joining, isTrue);
      expect(controller.state.error, isNull);

      gateB.complete();
      await joinB;
      expect(controller.state.channelId, 'chan-b');
      expect(controller.state.joining, isFalse);
      expect(controller.state.error, isNull);
    },
  );

  test('a leave during a still-pending join is not overwritten once the '
      'abandoned join finally answers', () async {
    final gate = Completer<void>();
    final controller = harness.controllerWith(FakeSession(), gatedClient(gate));

    final join = controller.join('chan-a');
    await controller.leave();
    expect(controller.state.channelId, isNull);
    expect(controller.state.joining, isFalse);

    gate.complete();
    await join;

    // The join this leave abandoned must not resurrect a channel or an error.
    expect(controller.state.channelId, isNull);
    expect(controller.state.joining, isFalse);
    expect(controller.state.error, isNull);
  });
}
