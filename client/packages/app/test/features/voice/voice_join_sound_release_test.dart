// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A ring or chime still playing must let go of the audio session before the call connects.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/sound_session_release.dart';

import 'voice_controller_harness.dart';

class _LoggingSession extends FakeSession {
  _LoggingSession(this.log);

  final List<String> log;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) {
    log.add('connect');
    return super.join(
      url: url,
      token: token,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
      canPublish: canPublish,
    );
  }
}

void main() {
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  test(
    'the sounds are stopped, and done stopping, before the connect',
    () async {
      final log = <String>[];
      final release = Completer<void>();
      final controller = harness.controllerWith(
        _LoggingSession(log),
        voiceApi(),
        extraOverrides: [
          soundSessionReleaseProvider.overrideWithValue(() async {
            log.add('stop');
            await release.future;
            log.add('stopped');
          }),
        ],
      );

      final joining = controller.join('chan-a');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(log, ['stop'], reason: 'the connect waits for the stop to finish');

      release.complete();
      await joining;
      expect(log, ['stop', 'stopped', 'connect']);
    },
  );
}
