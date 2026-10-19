// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas overflow menu's two additions: "Clear part of the canvas" (a
/// scope picked in a sheet, then confirmed) and "Participants" (the call's
/// people, each opening the menu their call tile has).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_overflow_menu.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_clear_scope.dart';
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

Future<void> _pump(
  WidgetTester tester, {
  CanvasScopedClear? scopedClear,
  bool inCall = false,
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
          inCall ? [_bob] : const <VoiceParticipant>[],
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
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
  );
  await tester.tap(find.bySemanticsLabel('More canvas actions'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no scoped clear item without the control', (tester) async {
    await _pump(tester);

    expect(find.text('Clear canvas'), findsOneWidget);
    expect(find.text('Clear part of the canvas'), findsNothing);
  });

  testWidgets('picking a kind confirms, then clears just that kind', (
    tester,
  ) async {
    final cleared = <api.CanvasClearScope>[];
    await _pump(
      tester,
      scopedClear: CanvasScopedClear(
        clear: (scope) async => cleared.add(scope),
        authorIds: () => {'ann'},
      ),
    );

    await tester.tap(find.text('Clear part of the canvas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All images'));
    await tester.pumpAndSettle();
    expect(cleared, isEmpty, reason: 'a pick alone must not clear');
    expect(find.text('Clear all images?'), findsOneWidget);

    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();

    expect(cleared.single.kinds, ['image']);
    expect(cleared.single.authorId, isNull);
  });

  testWidgets('picking a person clears just their content', (tester) async {
    final cleared = <api.CanvasClearScope>[];
    await _pump(
      tester,
      scopedClear: CanvasScopedClear(
        clear: (scope) async => cleared.add(scope),
        authorIds: () => {'ann'},
      ),
    );

    await tester.tap(find.text('Clear part of the canvas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ann'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();

    expect(cleared.single.authorId, 'ann');
    expect(cleared.single.kinds, isEmpty);
  });

  testWidgets('declining the confirm clears nothing', (tester) async {
    final cleared = <api.CanvasClearScope>[];
    await _pump(
      tester,
      scopedClear: CanvasScopedClear(
        clear: (scope) async => cleared.add(scope),
        authorIds: () => const {},
      ),
    );

    await tester.tap(find.text('Clear part of the canvas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All drawings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();

    expect(cleared, isEmpty);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('Participants opens the call tile menu at $width wide', (
      tester,
    ) async {
      await _pump(tester, inCall: true, size: Size(width, 800));

      await tester.tap(find.text('Participants'));
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsOneWidget);

      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();

      expect(find.text('Mute for me'), findsOneWidget);
    });
  }

  testWidgets('Participants is absent outside this channel\'s call', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Participants'), findsNothing);
  });
}
