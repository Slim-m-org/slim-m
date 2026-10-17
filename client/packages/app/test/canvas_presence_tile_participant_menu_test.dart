// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A presence tile's own right-click/long-press menu now also carries
/// whatever `CanvasPresenceLayer.participantMenuItemsBuilder` hands it for
/// that tile's participant - volume, mute for me, view profile, moderate in
/// production (`participant_call_menu.dart`), a plain stub here so this file
/// stays about the wiring and the gesture, not that menu's own content.
///
/// The right-click is driven as a real mouse down-hold-up, not `tapAt`,
/// since `onSecondaryTapUp` only fires for the arena's actual winner on the
/// up event - see `context_menu_region_nesting_test.dart`'s own doc for the
/// bug that shape of test exists to catch. The long press uses
/// `tester.longPressAt`, the same real down-hold-up sequence
/// `canvas_object_context_menu_long_press_test.dart` already established for
/// this canvas's own touch equivalent.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _noor = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _tileKey = ValueKey('camera:user-noor');

Widget _wrap({
  required CanvasDocument document,
  required CanvasPresenceTileOverrides overrides,
  required List<VoiceParticipant> participants,
}) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: SizedBox(
        width: 1200,
        height: 800,
        child: CanvasPresenceLayer(
          document: document,
          participants: participants,
          cameraViewFor: (_) => const SizedBox(),
          screenShareViewFor: (_) => const SizedBox(),
          overrides: overrides,
          onCommit: (_, __) {},
          participantMenuItemsBuilder: (context, participant, close) => [
            AppMenuItem(
              label: 'STUB for ${participant.identity}',
              onTap: close,
            ),
          ],
        ),
      ),
    ),
  ),
);

/// A right-click the way a mouse makes one: pressed, held past
/// [kPressTimeout], released.
Future<void> _rightClick(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a right-click on a remote tile carries the participant rows ahead of '
    "the tile's own chrome verbs",
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1200, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      await tester.pumpWidget(
        _wrap(
          document: document,
          overrides: overrides,
          participants: const [_noor],
        ),
      );
      await tester.pump();

      await _rightClick(tester, tester.getCenter(find.byKey(_tileKey)));

      expect(find.text('STUB for user-noor'), findsOneWidget);
      expect(find.text('Hide on your canvas'), findsOneWidget);
    },
  );

  testWidgets('a long press on a remote tile opens the same menu, the touch '
      'equivalent desktop-vs-mobile law 3 requires', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1200, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    await tester.pumpWidget(
      _wrap(
        document: document,
        overrides: overrides,
        participants: const [_noor],
      ),
    );
    await tester.pump();

    await tester.longPressAt(tester.getCenter(find.byKey(_tileKey)));
    await tester.pumpAndSettle();

    expect(find.text('STUB for user-noor'), findsOneWidget);
  });

  testWidgets(
    'tapping the participant row closes the menu, the same as any other row',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1200, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      await tester.pumpWidget(
        _wrap(
          document: document,
          overrides: overrides,
          participants: const [_noor],
        ),
      );
      await tester.pump();
      await _rightClick(tester, tester.getCenter(find.byKey(_tileKey)));
      expect(find.text('STUB for user-noor'), findsOneWidget);

      await tester.tap(find.text('STUB for user-noor'));
      await tester.pumpAndSettle();

      expect(find.text('STUB for user-noor'), findsNothing);
    },
  );
}
