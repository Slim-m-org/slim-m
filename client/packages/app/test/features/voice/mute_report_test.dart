// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A deliberate mute or unmute tells the channel, so people outside the call
/// see the icon; a push-to-talk press does not, or every press would make
/// everyone watching the channel refetch it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  http.Client api(List<String> puts) => voiceApi(
    onRequest: (r) {
      if (r.url.path.endsWith('/voice/muted')) {
        puts.add('${r.method} ${r.url.path} ${r.body}');
      }
    },
  );

  test('muting and unmuting each tell the channel', () async {
    final puts = <String>[];
    final controller = harness.controllerWith(FakeSession(), api(puts));
    await controller.join('lounge');
    final openAtJoin = controller.state.microphoneEnabled;

    await controller.toggleMicrophone();
    await controller.toggleMicrophone();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(puts, [
      'PUT /channels/lounge/voice/muted {"muted":$openAtJoin}',
      'PUT /channels/lounge/voice/muted {"muted":${!openAtJoin}}',
    ]);
  });

  test('a toggle the microphone refused tells nobody', () async {
    final puts = <String>[];
    final controller = harness.controllerWith(
      FakeSession(microphoneGranted: false),
      api(puts),
    );
    await controller.join('lounge');

    await controller.toggleMicrophone();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(puts, isEmpty);
  });

  test('push-to-talk presses tell nobody', () async {
    final puts = <String>[];
    final session = FakeSession();
    final controller = harness.controllerWith(session, api(puts));
    await controller.join('lounge');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();

    await controller.input.setPushToTalkHeld(true);
    expect(controller.state.microphoneEnabled, isTrue);
    await controller.input.setPushToTalkHeld(false);
    expect(controller.state.microphoneEnabled, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(puts, isEmpty);
  });
}
