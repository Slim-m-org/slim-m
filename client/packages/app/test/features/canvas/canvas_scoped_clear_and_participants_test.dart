// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas overflow menu's two additions: "Clear part of the canvas" (a
/// scope picked in a sheet, then confirmed) and "Participants" (the call's
/// people, each opening the menu their call tile has); a sheet opened from it
/// takes keyboard focus so pane hotkeys stay quiet behind it.
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
  bool paneHotkeys = false,
  CanvasScopedClear? scopedClear,
  bool inCall = false,
  bool speaking = false,
  bool onlyYou = false,
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final home = Scaffold(
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
  );
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
        home: paneHotkeys
            ? CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.keyE): () =>
                      paneKeys.add('e'),
                },
                child: Focus(key: _paneFocus, autofocus: true, child: home),
              )
            : home,
      ),
    ),
  );
  await tester.tap(find.bySemanticsLabel('More canvas actions'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(paneKeys.clear);

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

  testWidgets('the wide Participants dialog lays its rows out inside itself', (
    tester,
  ) async {
    await _pump(tester, inCall: true, speaking: true);

    await tester.tap(find.text('Participants'));
    // A speaking ring never settles, so step frames the way a running app gets them.
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final dialog = tester.getRect(find.byType(CanvasParticipantsSheet));
    final row = tester.getRect(find.text('Bob'));
    expect(dialog.width, greaterThan(200));
    expect(dialog.height, greaterThan(60));
    expect(dialog.height, lessThan(300));
    expect(row.isEmpty, isFalse);
    expect(dialog.contains(row.center), isTrue);
    expect(find.byType(Dialog), findsOneWidget);
  });

  testWidgets('this device\'s own row offers no menu it cannot open', (
    tester,
  ) async {
    await _pump(tester, inCall: true, onlyYou: true);

    await tester.tap(find.text('Participants'));
    await tester.pumpAndSettle();

    expect(find.text('You'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(CanvasParticipantsSheet),
        matching: find.byIcon(AppIcons.moreVertical),
      ),
      findsNothing,
    );
  });

  testWidgets('Participants is absent outside this channel\'s call', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Participants'), findsNothing);
  });

  testWidgets('Participants sheet takes focus and pane hotkeys stay quiet', (
    tester,
  ) async {
    await _pump(tester, inCall: true, paneHotkeys: true);
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
