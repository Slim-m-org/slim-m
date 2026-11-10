// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas menus opened from the real pane: the dock's overflow, the object and empty-space menus, a camera tile's menu and the tool wheel, dark and light.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_canvas_board.dart';
import 'ui_review_canvas_rig.dart';

Future<void> _openOverflow(CanvasReviewRig rig) async {
  await rig.tester.tap(find.byTooltip('More canvas actions').first);
  await rig.tester.pump();
  await rig.settle();
}

Future<CanvasReviewRig> _sparse(
  WidgetTester tester,
  String viewport, {
  bool onCall = false,
  int permissions = 0,
}) => mountReviewCanvas(
  tester,
  viewport,
  objects: sparseBoard(phone: viewport == 'phone'),
  call: onCall ? reviewCall : null,
  permissions: permissions,
);

/// Opens the object menu the way the viewport's own input does: a right-click, or a long press on touch.
Future<void> _openObjectMenu(CanvasReviewRig rig, String id) {
  // Unfilled shapes are only hit on their outline, everything else at the middle.
  final at = id == 'box-solo' ? rig.edgeOf(id) : rig.centreOf(id);
  return rig.desktop ? rig.rightClick(at) : rig.longPress(at);
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewCanvasViewports.keys) {
    testWidgets('menu-canvas-overflow default $viewport', (tester) async {
      final rig = await _sparse(tester, viewport);
      await _openOverflow(rig);
      await rig.capture('menu-canvas-overflow', state: 'default');
    });

    testWidgets('menu-canvas-overflow in-call $viewport', (tester) async {
      final rig = await _sparse(tester, viewport, onCall: true);
      await _openOverflow(rig);
      await rig.capture('menu-canvas-overflow', state: 'in-call');
    });

    testWidgets('menu-canvas-overflow selection $viewport', (tester) async {
      final rig = await _sparse(tester, viewport, onCall: true);
      await rig.leftClick(rig.centreOf('note-solo'));
      expect(rig.document.selectedObjectId.value, 'note-solo');
      await _openOverflow(rig);
      await rig.capture('menu-canvas-overflow', state: 'selection');
    });

    testWidgets('menu-canvas-overflow manager $viewport', (tester) async {
      final rig = await _sparse(
        tester,
        viewport,
        onCall: true,
        permissions: Perm.manageCanvas,
      );
      await _openOverflow(rig);
      await rig.capture('menu-canvas-overflow', state: 'manager');
    });

    for (final (state, id) in const [
      ('single', 'box-solo'),
      ('note', 'note-solo'),
      ('image', reviewImageId),
    ]) {
      testWidgets('menu-canvas-object $state $viewport', (tester) async {
        final rig = await _sparse(tester, viewport, onCall: true);
        await _openObjectMenu(rig, id);
        expect(rig.document.selectedObjectId.value, id);
        await rig.capture('menu-canvas-object', state: state);
      });
    }

    testWidgets('menu-canvas-object empty-space $viewport', (tester) async {
      final rig = await _sparse(tester, viewport, onCall: true);
      final at = rig.screenOf(
        rig.desktop ? const Offset(1400, 900) : const Offset(900, 300),
      );
      await (rig.desktop ? rig.rightClick(at) : rig.longPress(at));
      await rig.capture('menu-canvas-object', state: 'empty-space');
    });

    for (final (state, who) in const [('other', 'user-ada'), ('own', 'me')]) {
      testWidgets('menu-canvas-presence-tile $state $viewport', (tester) async {
        final rig = await mountReviewCanvas(
          tester,
          viewport,
          objects: sparseBoard(phone: viewport == 'phone'),
          call: reviewCallCameras,
        );
        final tile = find.byKey(ValueKey('camera:$who'));
        final at = tester.getCenter(tile);
        await (rig.desktop ? rig.rightClick(at) : rig.longPress(at));
        await rig.capture('menu-canvas-presence-tile', state: state);
      });
    }
  }

  testWidgets('overlay-canvas-tool-wheel open desktop', (tester) async {
    final rig = await mountReviewCanvas(
      tester,
      'desktop',
      objects: populatedBoard(phone: false),
      call: reviewCall,
    );
    final hold = await tester.startGesture(
      rig.screenOf(const Offset(1750, 560)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await rig.settle();
    await rig.capture('overlay-canvas-tool-wheel', state: 'open');
    await hold.up();
    await tester.pump();
  });
}
