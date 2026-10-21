// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wiring `canvas_pane.dart`'s overflow menu to `canvasSelfPresenceProvider`
/// end to end: hiding the caller's own camera bubble from the menu removes
/// it, showing it again restores it, and the choice survives reopening the
/// canvas the same way any other persisted preference does.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/canvas/canvas_pane_harness.dart';
import 'features/voice/voice_controller_harness.dart';
import 'support/fake_blocks.dart';

const _local = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
  isCameraOn: true,
);

ProviderContainer _containerWithSelfInCall() => CanvasPaneFixture().container(
  extraOverrides: [
    voiceControllerProvider.overrideWith(
      (ref) => FixedVoiceController(
        ref,
        const VoiceState(channelId: 'c1', participants: [_local]),
      ),
    ),
    blocksProvider.overrideWith(
      (ref) => FixedBlocksController(ref, const BlocksState()),
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'hiding from the overflow menu removes the bubble, and showing it '
    'again brings it back',
    (tester) async {
      final container = _containerWithSelfInCall();
      addTearDown(container.dispose);
      await pumpCanvasPane(tester, container);
      expect(find.byType(CanvasPresenceBubble), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide my camera bubble'));
      await tester.pump();

      expect(find.byType(CanvasPresenceBubble), findsNothing);

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      expect(find.text('Show my camera bubble'), findsOneWidget);

      await tester.tap(find.text('Show my camera bubble'));
      await tester.pump();

      expect(find.byType(CanvasPresenceBubble), findsOneWidget);
    },
  );

  testWidgets('hiding persists across reopening the canvas', (tester) async {
    final first = _containerWithSelfInCall();
    await pumpCanvasPane(tester, first);
    expect(find.byType(CanvasPresenceBubble), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide my camera bubble'));
    await tester.pump();
    expect(find.byType(CanvasPresenceBubble), findsNothing);

    // A real unmount first, or disposing `first` under a still-mounted widget leaves a pending Timer.
    await tester.pumpWidget(const SizedBox.shrink());
    first.dispose();

    // A fresh pane: nothing carries the choice forward except what was written to (mocked) disk.
    final second = _containerWithSelfInCall();
    addTearDown(second.dispose);
    await pumpCanvasPane(tester, second);

    expect(find.byType(CanvasPresenceBubble), findsNothing);
  });
}
