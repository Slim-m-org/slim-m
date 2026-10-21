// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-090: a sheet opened from the canvas overflow menu must take keyboard
/// focus, so pane hotkeys do not fire behind the modal barrier.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_overflow_menu.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_clear_scope.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_participants_sheet.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../voice/voice_call_controls_harness.dart' show InertSession;

const _ann = api.UserProfile(
  id: 'ann',
  username: 'ann',
  displayName: 'Ann',
  createdAt: 0,
);

const _bob = VoiceParticipant(
  identity: 'bob',
  name: 'Bob',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const _you = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

const _bobTalking = VoiceParticipant(
  identity: 'bob',
  name: 'Bob',
  isSpeaking: true,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

final paneKeys = <String>[];
const _paneFocus = ValueKey('pane focus');

Future<void> _pump(
  WidgetTester tester, {
  CanvasScopedClear? scopedClear,
  bool inCall = false,
  bool speaking = false,
  bool onlyYou = false,
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userProfileProvider('ann').overrideWith((ref) async => _ann),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: InertSession()),
        ),
        voiceParticipantsProvider.overrideWithValue(
          inCall
              ? (onlyYou ? [_you] : [speaking ? _bobTalking : _bob])
              : const <VoiceParticipant>[],
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyE): () =>
                paneKeys.add('e'),
          },
          child: Focus(
            key: _paneFocus,
            autofocus: true,
            child: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: CanvasOverflowMenu(
                  opensBelow: true,
                  onPasteImage: () {},
                  canDraw: true,
                  onToggleFullscreen: () {},
                  canManage: true,
                  onClear: () async {},
                  scopedClear: scopedClear,
                  selection: ValueNotifier(null),
                  onBringToFront: (_) {},
                  onSendToBack: (_) {},
                  onDeleteSelected: (_) {},
                  activityLogOpen: false,
                  onToggleActivityLog: () {},
                  tool: CanvasTool.pan,
                  shapeKind: CanvasShapeKind.rectangle,
                  onShapeKindChanged: (_) {},
                  hasSelfBubble: inCall,
                  selfBubbleHidden: false,
                  onToggleSelfBubbleHidden: () {},
                  hiddenTiles: const [],
                  onShowTile: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.bySemanticsLabel('More canvas actions'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(paneKeys.clear);

  testWidgets('Participants sheet takes focus and pane hotkeys stay quiet', (
    tester,
  ) async {
    await _pump(tester, inCall: true);
    await tester.tap(find.text('Participants'));
    await tester.pumpAndSettle();
    expect(find.byType(CanvasParticipantsSheet), findsOneWidget);

    final focusContext = FocusManager.instance.primaryFocus?.context;
    // The sheet's route holds focus; anything at or under the pane behind it would hear the hotkeys.
    final behind =
        focusContext == null ||
        find
            .descendant(
              of: find.byKey(_paneFocus),
              matching: find.byElementPredicate((e) => e == focusContext),
            )
            .evaluate()
            .isNotEmpty ||
        find.byKey(_paneFocus).evaluate().contains(focusContext);
    expect(behind, isFalse, reason: 'focus is on ${focusContext?.widget}');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    expect(paneKeys, isEmpty, reason: 'pane hotkey fired behind the sheet');
  });
}
