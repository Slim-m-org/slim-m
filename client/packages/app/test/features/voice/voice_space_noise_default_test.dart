// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Space default" noise suppression follows a Space change during a call and
/// survives a failed read, with the result reaching the session live.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/noise_suppression.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

class _Space {
  bool strong = false;
  bool failing = false;
  int reads = 0;
}

http.Client _client(_Space space) {
  final voice = voiceApi();
  return MockClient((request) async {
    if (request.url.path != '/version') {
      return http.Response.fromStream(await voice.send(request));
    }
    space.reads++;
    if (space.failing) return http.Response('', 503);
    return http.Response(
      jsonEncode({
        'name': 'slim-m',
        'version': '0.89.0',
        'protocol': 1,
        'strong_noise_suppression': space.strong,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

const _tick = Duration(milliseconds: 20);

Future<void> _recheck() => Future<void>.delayed(_tick * 3);

void main() {
  final harness = VoiceHarness();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    spaceNoiseSuppressionRecheck = _tick;
  });
  tearDown(() {
    spaceNoiseSuppressionRecheck = kSpaceNoiseSuppressionRecheck;
    harness.dispose();
  });

  test('an admin change mid-call reaches a member on Space default', () async {
    final space = _Space();
    final session = FakeSession();
    final controller = harness.controllerWith(session, _client(space));
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    expect(session.lastStrongNoiseSuppression, isNull);

    space.strong = true;
    await _recheck();
    expect(session.lastStrongNoiseSuppression, isTrue);

    space.strong = false;
    await _recheck();
    expect(session.lastStrongNoiseSuppression, isFalse);
  });

  test('a failed read keeps the last known default, not Standard', () async {
    final space = _Space()..strong = true;
    final session = FakeSession();
    final controller = harness.controllerWith(session, _client(space));
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await Future<void>.delayed(Duration.zero);
    expect(session.lastStrongNoiseSuppression, isTrue);

    space.failing = true;
    await _recheck();
    expect(space.reads, greaterThan(1));
    expect(session.lastStrongNoiseSuppression, isTrue);
  });

  test('a member who picked Standard is left alone by the Space', () async {
    final space = _Space();
    final session = FakeSession();
    final controller = harness.controllerWith(session, _client(space));
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    controller.setNoiseSuppression(NoiseSuppressionChoice.standard);

    space.strong = true;
    await _recheck();
    expect(session.lastStrongNoiseSuppression, isFalse);
  });

  test('leaving stops asking the server', () async {
    final space = _Space();
    final session = FakeSession();
    final controller = harness.controllerWith(session, _client(space));
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await controller.leave();
    await Future<void>.delayed(Duration.zero);
    final before = space.reads;
    await _recheck();
    expect(space.reads, before);
  });
}
