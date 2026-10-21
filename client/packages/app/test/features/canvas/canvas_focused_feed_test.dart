// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The focused feed outlives a voice reconnect (the roster empties for a
/// moment and the same people come back) but not a share that really ended.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_focused_feed.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

VoiceParticipant _ada({bool sharing = true}) => VoiceParticipant(
  identity: 'user-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: sharing,
);

Future<void> _pump(
  WidgetTester tester,
  CanvasDocument document,
  List<VoiceParticipant> participants,
  VoidCallback onLost,
) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: CanvasFocusedFeed(
        document: document,
        tileKey: 'screen:user-ada',
        participants: participants,
        cameraViewFor: (_) => const SizedBox(),
        screenShareViewFor: (_) => const ColoredBox(color: Colors.green),
        onLost: onLost,
      ),
    ),
  ),
);

void main() {
  late CanvasDocument document;
  setUp(() {
    document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..setViewport(const Size(1000, 800));
  });
  tearDown(() => document.dispose());

  testWidgets('an emptied roster keeps the focus through a reconnect', (
    tester,
  ) async {
    var lost = 0;
    await _pump(tester, document, [_ada()], () => lost++);
    await _pump(tester, document, const [], () => lost++);
    await tester.pump(focusedFeedGrace ~/ 2);
    expect(lost, 0, reason: 'still inside the grace');

    await _pump(tester, document, [_ada()], () => lost++);
    await tester.pump(focusedFeedGrace * 2);

    expect(lost, 0, reason: 'they came back');
    expect(find.byType(ColoredBox), findsWidgets);
  });

  testWidgets('a person who stays gone loses the focus after the grace', (
    tester,
  ) async {
    var lost = 0;
    await _pump(tester, document, const [], () => lost++);

    await tester.pump(focusedFeedGrace + const Duration(milliseconds: 1));

    expect(lost, 1);
  });

  testWidgets('a share that ended while its person stays drops the focus now', (
    tester,
  ) async {
    var lost = 0;
    await _pump(tester, document, [_ada(sharing: false)], () => lost++);
    await tester.pump();

    expect(lost, 1);
  });

  testWidgets('the camera is held at fit while the feed shows', (tester) async {
    await _pump(tester, document, [_ada()], () {});
    document.setCamera(
      document.camera.copyWith(zoom: document.camera.zoom * 3),
    );
    await tester.pump();

    expect(document.isFitted, isTrue);
  });
}
