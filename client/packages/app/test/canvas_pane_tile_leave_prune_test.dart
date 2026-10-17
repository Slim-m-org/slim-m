// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A dragged tile's override survives `CanvasPresenceLayer.didUpdateWidget`
/// pruning it when its owner leaves the call, without corrupting the frame
/// the dock's own `ListenableBuilder` (`canvas_pane_body.dart`) is mid-build
/// on - the two listen to the same `CanvasPresenceTileOverrides` and sit as
/// siblings in one `Stack`, so a prune's `notifyListeners()` reaching the
/// dock while the presence layer's own reconciliation is still in flight is
/// exactly the shape Flutter's "setState() or markNeedsBuild() called
/// during build" exists to catch.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/canvas/canvas_pane_harness.dart';
import 'features/voice/voice_controller_harness.dart';

class _MutableVoiceController extends VoiceController {
  _MutableVoiceController(super.ref, VoiceState initial)
    : super(session: FakeSession()) {
    state = initial;
  }

  void setParticipants(List<VoiceParticipant> participants) =>
      state = state.copyWith(participants: participants);
}

const _noor = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

void main() {
  testWidgets('a dragged tile\'s owner leaving the call does not crash the dock '
      'listening on the same overrides', (tester) async {
    final fixture = CanvasPaneFixture();
    late _MutableVoiceController controller;
    final container = fixture.container(
      extraOverrides: [
        voiceControllerProvider.overrideWith((ref) {
          controller = _MutableVoiceController(
            ref,
            const VoiceState(
              channelId: 'c1',
              state: VoiceSessionState.connected,
              participants: [_noor],
            ),
          );
          return controller;
        }),
      ],
    );
    addTearDown(container.dispose);

    await pumpCanvasPane(tester, container);

    // Drag Noor's tile so an override exists to prune - an empty store notifies nobody and would pass by luck.
    await tester.drag(find.byType(CanvasPresenceBubble), const Offset(50, 30));
    await tester.pump();

    controller.setParticipants(const []);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
