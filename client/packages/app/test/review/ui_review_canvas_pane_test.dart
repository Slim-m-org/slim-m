// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane on a call at desktop and phone width, in each state a person meets it in, dark and light.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_forbidden_message.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_canvas_board.dart';
import 'ui_review_canvas_rig.dart';

/// Wide-pane states, each on the populated board with the call dock up.
Future<CanvasReviewRig> _wide(
  WidgetTester tester, {
  int viewportStatus = 200,
  int? timedOutUntil,
}) => mountReviewCanvas(
  tester,
  'desktop',
  objects: populatedBoard(phone: false),
  call: reviewCall,
  viewportStatus: viewportStatus,
  timedOutUntil: timedOutUntil,
);

void _cursors(CanvasReviewRig rig) {
  rig.engine.cursors
    ..upsert(
      id: 'user-ada',
      x: 560,
      y: 420,
      label: 'Ada Lovelace',
      colorIndex: 1,
    )
    ..upsert(id: 'user-bo', x: 1340, y: 560, label: 'Bo', colorIndex: 4)
    ..upsert(
      id: 'user-cy',
      x: 1000,
      y: 800,
      label: 'Cy (mobile)',
      colorIndex: 2,
    );
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('canvas-pane-wide populated', (tester) async {
    final rig = await _wide(tester);
    await rig.capture('canvas-pane-wide', state: 'populated');
  });

  testWidgets('canvas-pane-wide selection', (tester) async {
    final rig = await _wide(tester);
    await rig.leftClick(rig.centreOf('note-keep'));
    await rig.rightClick(rig.centreOf('note-keep'));
    expect(rig.document.selectedObjectId.value, 'note-keep');
    await rig.capture('canvas-pane-wide', state: 'selection');
  });

  testWidgets('canvas-pane-wide remote-cursors', (tester) async {
    final rig = await _wide(tester);
    _cursors(rig);
    await rig.settle();
    await rig.capture('canvas-pane-wide', state: 'remote-cursors');
  });

  testWidgets('canvas-pane-wide follow-chip', (tester) async {
    final rig = await _wide(tester);
    _cursors(rig);
    rig.engine.viewRelay
      ..applyRemote(
        'user-ada',
        const Rect.fromLTWH(100, 80, 960, 540),
        summon: false,
      )
      ..follow('user-ada');
    await rig.settle();
    await rig.capture('canvas-pane-wide', state: 'follow-chip');
  });

  testWidgets('canvas-pane-wide personal-view', (tester) async {
    final rig = await _wide(tester);
    rig.engine.viewMode.toggle();
    await rig.settle();
    await rig.capture('canvas-pane-wide', state: 'personal-view');
  });

  testWidgets('canvas-pane-wide zoom-indicator', (tester) async {
    final rig = await _wide(tester);
    final photo = rig.document.objectBounds(reviewImageId)!;
    rig.document.setCamera(
      Camera(x: photo.x - 120, y: photo.y - 120, zoom: 1.6),
    );
    await rig.settle();
    await rig.capture('canvas-pane-wide', state: 'zoom-indicator');
  });

  testWidgets('canvas-pane-wide world-edge', (tester) async {
    final rig = await _wide(tester);
    rig.engine.tileOverrides.setRect(
      'camera:user-ada',
      const Rect.fromLTWH(99999, 99999, 220, 160),
    );
    await rig.settle();
    expect(rig.engine.tileOverrides.worldEdgeHit.value, isTrue);
    await rig.capture('canvas-pane-wide', state: 'world-edge');
  });

  testWidgets('canvas-pane-wide read-only', (tester) async {
    final rig = await _wide(tester, viewportStatus: 403);
    await rig.settle();
    await rig.capture('canvas-pane-wide', state: 'read-only');
  });

  testWidgets('canvas-pane-wide timed-out', (tester) async {
    final until = DateTime.now().add(const Duration(minutes: 12, seconds: 30));
    final rig = await _wide(
      tester,
      timedOutUntil: until.millisecondsSinceEpoch,
    );
    rig.engine.reportError(
      canvasDrawForbiddenMessage(until.millisecondsSinceEpoch),
    );
    await rig.settle();
    await rig.capture('canvas-pane-wide', state: 'timed-out');
  });

  testWidgets('canvas-pane-phone populated', (tester) async {
    final rig = await mountReviewCanvas(
      tester,
      'phone',
      objects: populatedBoard(phone: true),
      call: reviewCall,
    );
    await rig.capture('canvas-pane-phone', state: 'populated');
  });

  testWidgets('canvas-pane-phone tool-options', (tester) async {
    final rig = await mountReviewCanvas(
      tester,
      'phone',
      objects: populatedBoard(phone: true),
      call: reviewCall,
    );
    await tester.tap(find.bySemanticsLabel('Pen'));
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.chevronDown));
    await rig.settle();
    await rig.capture('canvas-pane-phone', state: 'tool-options');
  });

  for (final viewport in reviewCanvasViewports.keys) {
    testWidgets('canvas-fullscreen default $viewport', (tester) async {
      final rig = await mountReviewCanvas(
        tester,
        viewport,
        objects: populatedBoard(phone: viewport == 'phone'),
        call: reviewCall,
        overrides: [canvasFullscreenProvider.overrideWith((ref) => 'c1')],
      );
      await rig.settle();
      await rig.capture('canvas-fullscreen');
    });
  }
}
