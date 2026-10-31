// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for joining the one call this client can be in: the token round
/// trip, the insecure-scheme refusal, and how a join failure is reported.
///
/// What happens once a call is live - toggling the microphone, the camera,
/// screen sharing, deafening, and leaving - is `voice_controller_live_call_test.dart`,
/// split out to stay under this repo's file budget. Both share a harness;
/// the iOS broadcast handoff has its own suite too.
library;

import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(harness.dispose);

  test('a listen-only token never asks for a microphone', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(canPublish: false),
    );

    await controller.join('channel-1');

    expect(controller.state.canPublish, isFalse);
    // Asking for a track the token forbids only produces a failure to report.
    expect(session.askedForMicrophoneOnJoin, isFalse);
  });

  test('a publishing token opens the microphone the user asked for', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');

    expect(controller.state.canPublish, isTrue);
    expect(session.askedForMicrophoneOnJoin, isTrue);
    expect(controller.state.error, isNull);
  });

  test('the camera stays off by default before joining', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    expect(controller.state.cameraEnabled, isFalse);
    await controller.join('channel-1');

    expect(session.askedForCameraOnJoin, isFalse);
  });

  test('a camera pre-toggle set before joining reaches the session', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    controller.setCameraPreference(true);
    await controller.join('channel-1');

    expect(controller.state.cameraEnabled, isTrue);
    expect(session.askedForCameraOnJoin, isTrue);
  });

  test(
    'the persisted camera-on-join preference reaches the next join',
    () async {
      SharedPreferences.setMockInitialValues({
        'slimm.voice.camera_on_join': true,
      });
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());

      await controller.restoreCameraPreference();
      await controller.join('channel-1');

      expect(controller.state.cameraEnabled, isTrue);
      expect(session.askedForCameraOnJoin, isTrue);
    },
  );

  test('the persisted voice-activity sensitivity reaches the session before '
      'any call is joined', () async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.activity_sensitivity': 40.0,
    });
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.input.restoreVoiceActivitySensitivity();

    expect(session.lastSpeakingSensitivity, 0.4);
  });

  test(
    'with no persisted sensitivity, restoring keeps the old default',
    () async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());

      await controller.input.restoreVoiceActivitySensitivity();

      expect(session.lastSpeakingSensitivity, 1.0);
    },
  );

  test('changing sensitivity live reaches the session immediately', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    controller.input.setVoiceActivitySensitivity(70);

    expect(session.lastSpeakingSensitivity, 0.7);
  });

  test(
    'with no persisted preference, restoring leaves the camera off',
    () async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());

      await controller.restoreCameraPreference();
      await controller.join('channel-1');

      expect(session.askedForCameraOnJoin, isFalse);
    },
  );

  test('a listen-only token never asks for a camera either', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(canPublish: false),
    );

    controller.setCameraPreference(true);
    await controller.join('channel-1');

    // Same reasoning as the microphone: a forbidden track only reports.
    expect(session.askedForCameraOnJoin, isFalse);
  });

  test('a plain-ws SFU on a public address is refused, not joined', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(sfuUrl: 'ws://sfu.example.com'),
    );

    await controller.join('channel-1');

    expect(controller.state.state, VoiceSessionState.failed);
    expect(controller.state.error, contains('SLIMM_LIVEKIT_URL'));
    expect(
      controller.state.retryable,
      isFalse,
      reason: 'a misconfigured scheme fails identically on every retry',
    );
    expect(
      session.askedForMicrophoneOnJoin,
      isNull,
      reason: 'the session must never be asked to join an insecure SFU',
    );
  });

  test('a plain-ws SFU on a LAN address still joins', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(sfuUrl: 'ws://10.0.0.100:7880'),
    );

    await controller.join('channel-1');

    expect(controller.state.error, isNull);
    expect(session.askedForMicrophoneOnJoin, isTrue);
  });

  test('a wss SFU joins normally', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(sfuUrl: 'wss://sfu.example.com'),
    );

    await controller.join('channel-1');

    expect(controller.state.error, isNull);
    expect(session.askedForMicrophoneOnJoin, isTrue);
  });

  /// `SLIMM_LIVEKIT_URL` takes four schemes, not two - `voice/mod.rs`'s
  /// `http_url_for` accepts `wss`, `ws`, `https` and `http`, because LiveKit
  /// serves signalling on both pairs. Checking only for `wss` would refuse a
  /// perfectly secure deployment, which is a worse failure than the one this
  /// exists to prevent.
  test('an https SFU joins, and a plain-http public one is refused', () async {
    final secure = FakeSession();
    await harness
        .controllerWith(secure, voiceApi(sfuUrl: 'https://sfu.example.com'))
        .join('channel-1');
    expect(secure.askedForMicrophoneOnJoin, isTrue);

    final plain = FakeSession();
    final controller = harness.controllerWith(
      plain,
      voiceApi(sfuUrl: 'http://sfu.example.com'),
    );
    await controller.join('channel-1');
    expect(controller.state.state, VoiceSessionState.failed);
    expect(controller.state.retryable, isFalse);
    expect(plain.askedForMicrophoneOnJoin, isNull);
  });

  test(
    'a server with no voice says so, and is not a retryable failure',
    () async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi(status: 501));

      await controller.join('channel-1');

      expect(controller.state.state, VoiceSessionState.failed);
      expect(controller.state.error, contains('no voice configured'));
      expect(
        controller.state.retryable,
        isFalse,
        reason: 'the server config will not change from clicking Join again',
      );
    },
  );

  test(
    'being refused the channel reads as permission, not as a fault',
    () async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi(status: 403));

      await controller.join('channel-1');

      expect(controller.state.state, VoiceSessionState.failed);
      expect(controller.state.error, contains('permission'));
      expect(
        controller.state.retryable,
        isFalse,
        reason: 'a permission denial will not change from clicking Join again',
      );
    },
  );

  /// The flagship regression this pass closes: `client_transport.dart` wraps
  /// any dropped connection in a string carrying the method, the path and the
  /// Dart exception, and that string used to reach this full-screen surface
  /// verbatim. A lost connection while joining a call is the reachable case
  /// (a mobile network transition), so this is the one the report named first.
  test(
    'a lost connection while joining renders a sentence, not the exception',
    () async {
      final session = FakeSession();
      final client = MockClient((request) async {
        throw const SocketException('connection refused');
      });
      final controller = harness.controllerWith(session, client);

      await controller.join('channel-1');

      expect(controller.state.state, VoiceSessionState.failed);
      expect(
        controller.state.error,
        isNot(contains('SocketException')),
        reason: 'a Dart exception string helps nobody and reads as a crash',
      );
      expect(controller.state.error, isNot(contains('/voice/token')));
      expect(
        controller.state.error,
        contains('the server could not be reached'),
      );
      expect(
        controller.state.retryable,
        isTrue,
        reason: 'a dropped connection might really succeed next time',
      );
    },
  );

  test(
    'a failed connection surfaces why, not just that, and stays retryable',
    () async {
      final session = FakeSession(joinOutcome: VoiceSessionState.failed);
      final controller = harness.controllerWith(session, voiceApi());

      await controller.join('channel-1');

      expect(controller.state.error, contains('the SFU refused'));
      expect(
        controller.state.retryable,
        isTrue,
        reason: 'a dropped connection might really succeed next time',
      );
    },
  );

  /// Uses the same controller throughout. An earlier version of this test
  /// built a second one, whose retryable defaults to true, so it passed even
  /// with the reset deleted.
  test('a retry after a non-retryable failure resets once it starts', () async {
    var status = 501;
    final client = MockClient((request) async {
      if (!request.url.path.endsWith('/voice/token')) {
        return http.Response('{}', 404);
      }
      if (status != 200) {
        return http.Response(
          jsonEncode({
            'error': {'code': 'nope', 'message': 'refused'},
          }),
          status,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'url': 'wss://sfu.example.com',
          'room': 'channel-1',
          'token': 'jwt',
          'expires_at': 0,
          'can_publish': true,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final controller = harness.controllerWith(FakeSession(), client);
    await controller.join('channel-1');
    expect(
      controller.state.retryable,
      isFalse,
      reason: 'a server with no voice is not worth retrying',
    );

    // The admin configures an SFU and the user tries again.
    status = 200;
    await controller.join('channel-1');

    expect(
      controller.state.retryable,
      isTrue,
      reason: 'the previous failure must not lock this controller out',
    );
    expect(controller.state.error, isNull);
  });
}
