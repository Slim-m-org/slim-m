// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notices laid over the canvas board and the follow and summon prompts, at phone and desktop width, dark and light.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_forbidden_message.dart';
import 'package:slimm_app/src/features/voice/providers/voice_state.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_canvas_board.dart';
import 'ui_review_canvas_rig.dart';

Future<CanvasReviewRig> _board(
  WidgetTester tester,
  String viewport, {
  List<Map<String, dynamic>>? objects,
  bool hasMore = false,
  int placeStatus = 201,
  int? timedOutUntil,
}) => mountReviewCanvas(
  tester,
  viewport,
  objects: objects ?? populatedBoard(phone: viewport == 'phone'),
  call: reviewCall,
  hasMore: hasMore,
  placeStatus: placeStatus,
  timedOutUntil: timedOutUntil,
);

/// Two objects past the board's edge, where the server would refuse them but an older client could still have left them.
List<Map<String, dynamic>> _withStrays(bool phone) => [
  ...populatedBoard(phone: phone),
  reviewNote(
    'stray-note',
    const Rect.fromLTWH(3100, 300, 300, 220),
    'Placed before the board had an edge',
    seq: 20,
  ),
  reviewShape(
    'stray-box',
    const Rect.fromLTWH(-1400, 200, 300, 200),
    'rectangle',
    seq: 21,
  ),
];

void _askToFollow(CanvasReviewRig rig, {required bool summon}) {
  final phone = !rig.desktop;
  rig.engine.cursors.upsert(
    id: 'user-ada',
    x: phone ? 500 : 900,
    y: phone ? 400 : 380,
    label: 'Ada Lovelace',
    colorIndex: 1,
  );
  rig.engine.viewRelay.applyRemote(
    'user-ada',
    const Rect.fromLTWH(100, 80, 960, 540),
    summon: summon,
  );
}

VoiceState _withoutAda(VoiceState call) => call.copyWith(
  participants: [
    for (final p in call.participants)
      if (p.identity != 'user-ada') p,
  ],
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewCanvasViewports.keys) {
    testWidgets('banner-canvas call-failed $viewport', (tester) async {
      final rig = await _board(tester, viewport);
      rig.voice.drop('c1');
      await rig.settle();
      await rig.capture('banner-canvas', state: 'call-failed');
    });

    testWidgets('banner-canvas error-retry $viewport', (tester) async {
      final rig = await _board(tester, viewport);
      rig.engine.reportError(CanvasEngine.genericLoadError);
      await rig.settle();
      await rig.capture('banner-canvas', state: 'error-retry');
    });

    testWidgets('banner-canvas capped $viewport', (tester) async {
      final rig = await _board(tester, viewport, hasMore: true);
      await rig.settle();
      await rig.capture('banner-canvas', state: 'capped');
    });

    testWidgets('banner-canvas ink-waiting $viewport', (tester) async {
      final rig = await _board(tester, viewport);
      rig.document.setUnsaved('underline', unsaved: true);
      await rig.settle();
      await rig.capture('banner-canvas', state: 'ink-waiting');
    });

    testWidgets('banner-canvas timed-out $viewport', (tester) async {
      final until = DateTime.now().add(const Duration(minutes: 47));
      final rig = await _board(
        tester,
        viewport,
        timedOutUntil: until.millisecondsSinceEpoch,
      );
      rig.engine.reportError(
        canvasDrawForbiddenMessage(until.millisecondsSinceEpoch),
      );
      await rig.settle();
      await rig.capture('banner-canvas', state: 'timed-out');
    });

    testWidgets('banner-canvas outside-board $viewport', (tester) async {
      final rig = await _board(
        tester,
        viewport,
        objects: _withStrays(viewport == 'phone'),
      );
      expect(rig.document.outsideBoardCount.value, 2);
      await rig.capture('banner-canvas', state: 'outside-board');
    });

    testWidgets('banner-canvas forbidden $viewport', (tester) async {
      final rig = await _board(tester, viewport, placeStatus: 403);
      await tester.tap(find.bySemanticsLabel('Pen'));
      await tester.pump();
      final from = rig.screenOf(
        rig.desktop ? const Offset(1700, 560) : const Offset(1000, 640),
      );
      final stroke = await tester.startGesture(from);
      for (var i = 1; i <= 6; i++) {
        await stroke.moveTo(from + Offset(14.0 * i, 9.0 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await stroke.up();
      await tester.pump();
      await rig.settle();
      await rig.capture('banner-canvas', state: 'forbidden');
    });

    testWidgets('prompt-canvas-summon request $viewport', (tester) async {
      final rig = await _board(
        tester,
        viewport,
        objects: sparseBoard(phone: viewport == 'phone'),
      );
      _askToFollow(rig, summon: true);
      await rig.settle();
      await rig.capture('prompt-canvas-summon', state: 'request');
    });

    testWidgets('prompt-canvas-summon following $viewport', (tester) async {
      final rig = await _board(
        tester,
        viewport,
        objects: sparseBoard(phone: viewport == 'phone'),
      );
      _askToFollow(rig, summon: false);
      rig.engine.viewRelay.follow('user-ada');
      await rig.settle();
      expect(rig.engine.viewRelay.following.value, 'user-ada');
      await rig.capture('prompt-canvas-summon', state: 'following');
    });

    testWidgets('prompt-canvas-summon followed-left $viewport', (tester) async {
      final rig = await _board(
        tester,
        viewport,
        objects: sparseBoard(phone: viewport == 'phone'),
      );
      _askToFollow(rig, summon: false);
      rig.engine.viewRelay.follow('user-ada');
      await rig.settle();
      rig.engine.cursors.remove('user-ada');
      rig.voice.replace(_withoutAda(reviewCall));
      await rig.settle();
      expect(rig.engine.viewRelay.following.value, isNull);
      await rig.capture('prompt-canvas-summon', state: 'followed-left');
    });
  }
}
