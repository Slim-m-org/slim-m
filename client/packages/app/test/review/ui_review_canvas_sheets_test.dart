// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas surfaces that cover the board: the activity log, the note sheet and its in-place editor, and the clear sheet and its confirm, dark and light.
/// Each theme is its own mount because a sheet keeps the theme it was pushed under. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_note_sheet.dart'
    show maxNoteTextBytes;
import 'package:slimm_app/src/permissions.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_canvas_board.dart';
import 'ui_review_canvas_rig.dart';

Future<CanvasReviewRig> _board(
  WidgetTester tester,
  String viewport,
  String theme, {
  int permissions = 0,
}) => mountReviewCanvas(
  tester,
  viewport,
  objects: populatedBoard(phone: viewport == 'phone'),
  call: reviewCall,
  theme: theme,
  permissions: permissions,
);

Future<void> _tapText(CanvasReviewRig rig, String label) async {
  await rig.tester.tap(find.text(label).first);
  await rig.tester.pump();
  await rig.settle();
}

Future<void> _openOverflow(CanvasReviewRig rig) async {
  await rig.tester.tap(find.byTooltip('More canvas actions').first);
  await rig.tester.pump();
  await rig.settle();
}

api.CanvasObject _placed(
  String id,
  String kind,
  String author, {
  Map<String, dynamic> props = const {},
}) => api.CanvasObject(
  id: id,
  kind: kind,
  zIndex: 1,
  x: 0,
  y: 0,
  w: 100,
  h: 100,
  props: props,
  authorId: author,
  seq: 1,
  createdAt: 0,
);

void _seedActivity(CanvasReviewRig rig) {
  rig.engine.activityLog
    ..recordPlacedLive(
      _placed(
        'n1',
        'note',
        'user-ada',
        props: {'text': 'Ask Ada whether the zoom pill still earns its corner'},
      ),
    )
    ..recordPlacedLive(_placed('s1', 'stroke', 'user-bo'))
    ..recordPlacedLive(_placed('i1', 'image', 'me'))
    ..recordMovedLive('op-4')
    ..recordRemovedLive('op-5', const ['s1', 's2'])
    ..recordRestoredLive('op-6', 2)
    ..recordClearedLive('op-7', scope: api.CanvasClearScope.everything);
}

Future<void> _openNoteSheet(CanvasReviewRig rig) async {
  await rig.tester.tap(find.bySemanticsLabel('Note'));
  await rig.tester.pump();
  await rig.tester.tapAt(
    rig.screenOf(
      rig.desktop ? const Offset(1700, 560) : const Offset(1050, 700),
    ),
  );
  await rig.tester.pump();
  await rig.settle();
}

Finder get _field => find.byWidgetPredicate((w) => w is EditableText);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewCanvasViewports.keys) {
    testWidgets('canvas-activity-log entries $viewport', (t) async {
      final rig = await _board(t, viewport, 'dark');
      _seedActivity(rig);
      await _openOverflow(rig);
      await _tapText(rig, 'Show activity log');
      await rig.capture('canvas-activity-log', state: 'entries');
    });

    testWidgets('canvas-activity-log empty $viewport', (t) async {
      final rig = await _board(t, viewport, 'dark');
      await _openOverflow(rig);
      await _tapText(rig, 'Show activity log');
      await rig.capture('canvas-activity-log', state: 'empty');
    });

    testWidgets('sheet-canvas-note empty $viewport', (t) async {
      await captureEachTheme(
        t,
        (theme) => _board(t, viewport, theme),
        _openNoteSheet,
        'sheet-canvas-note',
        state: 'empty',
      );
    });

    testWidgets('sheet-canvas-note autocomplete $viewport', (t) async {
      await captureEachTheme(
        t,
        (theme) => _board(t, viewport, theme),
        (rig) async {
          await _openNoteSheet(rig);
          await t.enterText(_field, 'Ping @a');
          await t.pump();
          await rig.settle();
        },
        'sheet-canvas-note',
        state: 'autocomplete',
      );
    });

    testWidgets('sheet-canvas-note at-limit $viewport', (t) async {
      await captureEachTheme(
        t,
        (theme) => _board(t, viewport, theme),
        (rig) async {
          await _openNoteSheet(rig);
          await t.enterText(_field, 'w' * (maxNoteTextBytes - 11));
          await t.pump();
          await t.enterText(_field, '${'w' * (maxNoteTextBytes - 11)} more');
          await t.pump();
          await rig.settle();
        },
        'sheet-canvas-note',
        state: 'at-limit',
      );
    });

    testWidgets('sheet-canvas-note in-place-editor $viewport', (t) async {
      final rig = await _board(t, viewport, 'dark');
      final at = rig.centreOf('note-keep');
      await (rig.desktop ? rig.rightClick(at) : rig.longPress(at));
      await _tapText(rig, 'Edit note');
      await rig.capture('sheet-canvas-note', state: 'in-place-editor');
    });

    testWidgets('sheet-canvas-clear per-kind $viewport', (t) async {
      await captureEachTheme(
        t,
        (theme) => _board(t, viewport, theme, permissions: Perm.manageCanvas),
        (rig) async {
          await _openOverflow(rig);
          await _tapText(rig, 'Clear part of the canvas');
        },
        'sheet-canvas-clear',
        state: 'per-kind',
      );
    });

    testWidgets('sheet-canvas-clear whole-canvas $viewport', (t) async {
      await captureEachTheme(
        t,
        (theme) => _board(t, viewport, theme, permissions: Perm.manageCanvas),
        (rig) async {
          await _openOverflow(rig);
          await _tapText(rig, 'Clear canvas');
        },
        'sheet-canvas-clear',
        state: 'whole-canvas',
      );
    });
  }
}
