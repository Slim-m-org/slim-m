// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message stops and keeps its clip when a phone backgrounds the app.
library;

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';

import 'voice_recording_test.dart' show Rig;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Rig> recording({required bool onPhone}) async {
    final rig = Rig(onPhone: onPhone)..listen();
    addTearDown(rig.container.dispose);
    await rig.recorder.start();
    await rig.advance(const Duration(seconds: 2));
    return rig;
  }

  void background(Rig rig) => rig.container
      .read(appLifecycleProvider.notifier)
      .didChangeAppLifecycleState(AppLifecycleState.paused);

  test('backgrounding a phone ends the recording and keeps the clip', () async {
    final rig = await recording(onPhone: true);

    background(rig);
    await pumpEventQueue();

    expect(rig.state.phase, VoicePhase.stopped);
    expect(rig.state.clip?.duration, const Duration(seconds: 2));
    expect(rig.capture.stopped, isTrue);
  });

  test('a desktop window going to the tray keeps recording', () async {
    final rig = await recording(onPhone: false);

    background(rig);
    await pumpEventQueue();

    expect(rig.state.phase, VoicePhase.recording);
  });

  test(
    'a brief inactive state on a phone does not end the recording',
    () async {
      final rig = await recording(onPhone: true);

      rig.container
          .read(appLifecycleProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.inactive);
      await pumpEventQueue();

      expect(rig.state.phase, VoicePhase.recording);
    },
  );
}
