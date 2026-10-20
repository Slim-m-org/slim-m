// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A fitted board shrinks an avatar tile to a few dozen pixels, so the hover
/// buttons must not sit on the pixel a mouse grabs it by.
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
);

const _tileKey = ValueKey('camera:user-noor');
const _hideLabel =
    'Hide this tile on your canvas; other participants still see it';

void main() {
  testWidgets('a mouse that hovered a small avatar tile still drags it', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    document.setCamera(document.camera.copyWith(zoom: 0.25));
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    var commits = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: SizedBox(
              width: 1000,
              height: 800,
              child: CanvasPresenceLayer(
                document: document,
                participants: const [_noor],
                cameraViewFor: (_) => const SizedBox(),
                screenShareViewFor: (_) => const SizedBox(),
                overrides: overrides,
                onCommit: (_, __) => commits++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final centre = tester.getCenter(find.byKey(_tileKey));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: centre);
    await tester.pump(AppMotion.fast);
    expect(find.bySemanticsLabel(_hideLabel).hitTestable(), findsNothing);

    await mouse.down(centre);
    await mouse.moveTo(centre + const Offset(40, 30));
    await mouse.up();
    await tester.pump();

    expect(commits, 1);
  });
}
