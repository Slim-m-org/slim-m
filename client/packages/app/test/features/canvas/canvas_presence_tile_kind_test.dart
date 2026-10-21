// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0086: only a live camera or screen share has a tile; a tile has resize, lock and hide but no depth control, since ink always paints above it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile_controls.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'presence_stack.dart';

const _avatarOnly = VoiceParticipant(
  identity: 'user-avatar',
  name: 'Avatar Only',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const _onCamera = VoiceParticipant(
  identity: 'user-video',
  name: 'On Camera',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _videoKey = ValueKey('camera:user-video');

Future<CanvasPresenceTileOverrides> _pump(WidgetTester tester) async {
  final document = CanvasDocument()..setViewport(const Size(1000, 800));
  addTearDown(document.dispose);
  final overrides = CanvasPresenceTileOverrides();
  addTearDown(overrides.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 800,
            child: PresenceStack(
              document: document,
              participants: const [_avatarOnly, _onCamera],
              cameraViewFor: (_) => const SizedBox(),
              screenShareViewFor: (_) => const SizedBox(),
              overrides: overrides,
              onCommit: (_, _) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return overrides;
}

void main() {
  testWidgets('a person with no camera and no share has no tile on the board', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.byType(CanvasPresenceManipulableTile), findsOneWidget);
    expect(find.byKey(const ValueKey('camera:user-avatar')), findsNothing);
  });

  testWidgets('a camera tile keeps resize, lock and hide, and has no depth '
      'control', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(_videoKey));
    await tester.pump(AppMotion.fast);

    final tile = find.byKey(_videoKey);
    expect(
      find.descendant(of: tile, matching: find.byType(TileResizeGrip)),
      findsOneWidget,
    );
    for (final label in [
      'Lock this tile in place',
      'Hide this tile on your canvas; other participants still see it',
    ]) {
      expect(
        find.descendant(of: tile, matching: find.bySemanticsLabel(label)),
        findsOneWidget,
        reason: label,
      );
    }
    for (final label in [
      'Send this tile to the back',
      'Bring this tile to the front',
    ]) {
      expect(
        find.descendant(of: tile, matching: find.bySemanticsLabel(label)),
        findsNothing,
        reason: label,
      );
    }
  });
}
