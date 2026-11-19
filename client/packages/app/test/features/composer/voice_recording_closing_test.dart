// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call starting waits for every microphone the recorder is still closing:
/// on Android a close that lands after the connect clears the call's
/// Bluetooth route.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/call_start_yields.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';

import 'voice_recording_test.dart' show Rig;

/// Starts a call and checks it gets past the recorder only once every one of
/// [closes] is completed, in order.
Future<void> expectCallWaitsFor(Rig rig, List<Completer<void>> closes) async {
  var yielded = false;
  final yielding = rig.container
      .read(callStartYieldsProvider)
      .callStarting()
      .then((_) => yielded = true);
  for (final close in closes) {
    await pumpEventQueue();
    expect(yielded, isFalse, reason: 'the microphone is still closing');
    close.complete();
  }
  await yielding;
}

void main() {
  late Rig rig;

  Future<void> recording() async {
    rig = Rig()..listen();
    addTearDown(rig.container.dispose);
    await rig.recorder.start();
    await rig.advance(const Duration(seconds: 3));
  }

  test(
    'a call starting waits for a recording already being finished',
    () async {
      await recording();
      final finish = Completer<void>();
      rig.capture.finishing = finish.future;
      final stopping = rig.recorder.stop();
      expect(rig.state.phase, VoicePhase.stopping);

      await expectCallWaitsFor(rig, [finish]);

      await stopping;
      expect(rig.capture.stopped, isTrue);
      expect(rig.state.phase, VoicePhase.stopped);
    },
  );

  test('a call starting waits for a recording discarded just before', () async {
    await recording();
    final discard = Completer<void>();
    rig.capture.discarding = discard.future;
    final discarding = rig.recorder.cancel();
    expect(rig.state.phase, VoicePhase.idle);

    await expectCallWaitsFor(rig, [discard]);

    await discarding;
    expect(rig.capture.cancelled, isTrue);
  });

  test(
    'a recording discarded while it finished is waited for as the next opens',
    () async {
      await recording();
      final finish = Completer<void>();
      rig.capture.finishing = finish.future;
      final stopping = rig.recorder.stop();
      await rig.recorder.cancel();
      final prompt = Completer<void>();
      rig.capture.opening = prompt.future;
      final starting = rig.recorder.start();
      expect(rig.state.phase, VoicePhase.starting);

      await expectCallWaitsFor(rig, [prompt, finish]);

      await starting;
      await stopping;
      expect(rig.state.phase, VoicePhase.idle);
    },
  );

  test(
    'a recorder let go while its microphone closes still holds the call',
    () async {
      rig = Rig();
      addTearDown(rig.container.dispose);
      final composer = rig.container.listen(
        voiceRecorderProvider('c1'),
        (_, _) {},
      );
      final recorder = rig.recorder;
      await recorder.start();
      await rig.advance(const Duration(seconds: 3));
      final finish = Completer<void>();
      rig.capture.finishing = finish.future;
      final stopping = recorder.stop();
      await recorder.cancel();
      composer.close();
      await pumpEventQueue();
      expect(rig.container.exists(voiceRecorderProvider('c1')), isFalse);

      await expectCallWaitsFor(rig, [finish]);

      await stopping;
      expect(rig.capture.stopped, isTrue);
    },
  );
}
