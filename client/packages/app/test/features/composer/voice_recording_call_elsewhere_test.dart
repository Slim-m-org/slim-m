// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a phone a call left running in another community still holds the one
/// audio session, so this community's composer refuses to record over it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/call_holds_audio_session.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';

import 'voice_recording_test.dart' show Rig;

void main() {
  test(
    'a phone refuses to record while another community is in a call',
    () async {
      final rig = Rig(
        onPhone: true,
        overrides: [callInAnotherAccountProvider.overrideWithValue(() => true)],
      )..listen();
      addTearDown(rig.container.dispose);

      await rig.recorder.start();

      expect(rig.state.phase, VoicePhase.failed);
      expect(rig.state.error, 'Leave the call to record a voice message.');
      expect(rig.capture.started, isFalse);
    },
  );
}
