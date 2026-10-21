// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tiles follow the view, not the content: a stroke landing or a remote preview
/// tick refreshes the document without moving the camera, and must not rebuild
/// every call tile.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_hidden_tiles.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_frame.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'presence_stack.dart';

const _noor = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

void main() {
  test(
    'the gate passes a camera or size change and blocks a content refresh',
    () {
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      addTearDown(document.dispose);
      final gate = CanvasViewChangeGate();

      expect(gate.changed(document), isTrue, reason: 'the first look');
      document.refresh();
      expect(gate.changed(document), isFalse);

      document.setCamera(document.camera.copyWith(zoom: 2));
      expect(gate.changed(document), isTrue);

      document.setViewport(const Size(900, 600));
      expect(gate.changed(document), isTrue);
    },
  );

  testWidgets('a content refresh rebuilds no tile, a camera move does', (
    tester,
  ) async {
    final document = CanvasDocument()
      ..setViewport(const Size(1000, 800))
      ..setCamera(const Camera());
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(document.dispose);
    addTearDown(overrides.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: PresenceStack(
              document: document,
              participants: const [_noor],
              cameraViewFor: (_) => const SizedBox(),
              screenShareViewFor: (_) => const SizedBox(),
              overrides: overrides,
              onCommit: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // The first look at the view always rebuilds once.
    document.refresh();
    await tester.pump();

    var rebuilt = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final name = element.widget.runtimeType.toString();
      if (name == 'CanvasPresenceManipulableTile') rebuilt++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    for (var i = 0; i < 10; i++) {
      document.refresh();
      await tester.pump();
    }
    expect(rebuilt, 0);

    document.setCamera(document.camera.copyWith(x: 40));
    await tester.pump();
    expect(rebuilt, greaterThan(0));
  });

  test('hidden tile keys announce a hide, not a drag', () {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final keys = HiddenTileKeys(overrides);
    addTearDown(keys.dispose);
    var told = 0;
    keys.addListener(() => told++);

    overrides.setRect('camera:a', const Rect.fromLTWH(0, 0, 100, 60));
    overrides.setRect('camera:a', const Rect.fromLTWH(10, 0, 100, 60));
    expect(told, 0);

    overrides.setHidden('camera:a', true);
    expect(told, 1);
    overrides.setHidden('camera:a', false);
    expect(told, 2);
  });
}
