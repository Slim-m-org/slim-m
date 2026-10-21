// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who is talking on the call reaches the canvas cursors, so the speaker's
/// cursor label glows (decision 0086).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_speaking_sync.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../voice/voice_controller_harness.dart';

class _Driven extends VoiceController {
  _Driven(super.ref) : super(session: FakeSession()) {
    state = const VoiceState(channelId: 'c1');
  }

  void become(List<VoiceParticipant> people) =>
      state = VoiceState(channelId: 'c1', participants: people);
}

VoiceParticipant _p(String id, {bool speaking = false, bool local = false}) =>
    VoiceParticipant(
      identity: id,
      name: id,
      isSpeaking: speaking,
      isMuted: false,
      isLocal: local,
      isScreenSharing: false,
    );

void main() {
  testWidgets('a speaker\'s cursor glows and stops when they do', (
    tester,
  ) async {
    late _Driven voice;
    final container = ProviderContainer(
      overrides: [
        voiceControllerProvider.overrideWith((ref) => voice = _Driven(ref)),
      ],
    );
    addTearDown(container.dispose);
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: CanvasSpeakingSync(cursors: cursors)),
      ),
    );

    voice.become([_p('me', local: true), _p('amy', speaking: true), _p('bo')]);
    await tester.pump();
    expect(cursors.isSpeaking('amy'), isTrue);
    expect(cursors.isSpeaking('bo'), isFalse);
    expect(
      cursors.isSpeaking('me'),
      isFalse,
      reason: 'your own cursor is not drawn',
    );

    voice.become([_p('me', local: true), _p('amy'), _p('bo', speaking: true)]);
    await tester.pump();
    expect(cursors.isSpeaking('amy'), isFalse);
    expect(cursors.isSpeaking('bo'), isTrue);
  });
}
