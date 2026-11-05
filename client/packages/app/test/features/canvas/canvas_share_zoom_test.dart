// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Zooming a screen-share tile on the canvas: ctrl+wheel zooms the video and not the board, a plain wheel still moves the board.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'presence_stack.dart';

const _sharer = VoiceParticipant(
  identity: 'ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

Future<CanvasDocument> _pump(WidgetTester tester) async {
  final document = CanvasDocument()..setViewport(const Size(1200, 800));
  addTearDown(document.dispose);
  final overrides = CanvasPresenceTileOverrides();
  addTearDown(overrides.dispose);
  final feed = ScreenAnnotationFeed(selfId: () => 'me');
  addTearDown(feed.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [screenAnnotationFeedProvider.overrideWithValue(feed)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 800,
            child: PresenceStack(
              document: document,
              participants: const [_sharer],
              cameraViewFor: (id) => const SizedBox(),
              screenShareViewFor: (id) => const SizedBox(key: Key('video')),
              overrides: overrides,
              onCommit: (_, _) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return document;
}

Future<void> _wheel(WidgetTester tester, double dy) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  final at = tester.getCenter(find.byKey(const Key('video')));
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  testWidgets('ctrl+wheel over a share zooms its video, not the board', (
    tester,
  ) async {
    final document = await _pump(tester);
    final before = document.camera;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await _wheel(tester, -100);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(find.byKey(const ValueKey('share-zoom-level')), findsOneWidget);
    final video = tester.widget<Transform>(
      find.byKey(const ValueKey('share-zoom-transform')),
    );
    expect(video.transform.getMaxScaleOnAxis(), greaterThan(1));
    expect(document.camera, before);
  });

  testWidgets('a plain wheel over a share still moves the board', (
    tester,
  ) async {
    final document = await _pump(tester);
    final before = document.camera;
    await _wheel(tester, 100);

    expect(find.byKey(const ValueKey('share-zoom-level')), findsNothing);
    expect(document.camera, isNot(before));
  });

  testWidgets('resetting the zoom puts the video back to fit', (tester) async {
    await _pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await _wheel(tester, -100);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.byKey(const ValueKey('share-zoom-reset')));
    await tester.pump();

    final video = tester.widget<Transform>(
      find.byKey(const ValueKey('share-zoom-transform')),
    );
    expect(video.transform.getMaxScaleOnAxis(), 1);
  });
}
