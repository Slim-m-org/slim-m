// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opening and saving the in-place note editor through the whole pane: a
/// double click with a mouse or a tap with a finger on a note the person may
/// edit, never on one they may not, and Save posting one `edit` op that undo
/// and redo reverse.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_editor.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

Future<CanvasPaneFixture> _openPane(
  WidgetTester tester, {
  String authorId = 'me',
  int channelPermissions = 0,
}) async {
  final fixture = CanvasPaneFixture(channelPermissions: channelPermissions)
    ..objects = [canvasNoteJson('note', authorId: authorId, text: 'before')];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('Pan'));
  await tester.pump();
  return fixture;
}

Future<void> _mouseClick(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await gesture.up();
  await tester.pump();
}

const _onNote = Offset(15, 15);

void main() {
  testWidgets('a double click with a mouse opens the editor on the note', (
    tester,
  ) async {
    await _openPane(tester);
    final at = screenFor(tester, _onNote);

    await _mouseClick(tester, at);
    expect(find.byType(CanvasNoteEditor), findsNothing);
    await tester.pump(const Duration(milliseconds: 120));
    await _mouseClick(tester, at);

    expect(find.byType(CanvasNoteEditor), findsOneWidget);
    expect(find.text('before'), findsOneWidget);
  });

  testWidgets('two clicks too far apart in time are not a double click', (
    tester,
  ) async {
    await _openPane(tester);
    final at = screenFor(tester, _onNote);

    await _mouseClick(tester, at);
    await tester.pump(const Duration(seconds: 2));
    await _mouseClick(tester, at);

    expect(find.byType(CanvasNoteEditor), findsNothing);
  });

  testWidgets('a single tap with a finger opens the editor', (tester) async {
    await _openPane(tester);

    await tester.tapAt(screenFor(tester, _onNote));
    await tester.pump();

    expect(find.byType(CanvasNoteEditor), findsOneWidget);
  });

  testWidgets('dragging a note never opens the editor', (tester) async {
    await _openPane(tester);

    final gesture = await tester.startGesture(screenFor(tester, _onNote));
    await gesture.moveTo(screenFor(tester, const Offset(45, 35)));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(CanvasNoteEditor), findsNothing);
  });

  testWidgets("someone else's note does not open for a plain member", (
    tester,
  ) async {
    await _openPane(tester, authorId: 'other');

    await tester.tapAt(screenFor(tester, _onNote));
    await tester.pump();

    expect(find.byType(CanvasNoteEditor), findsNothing);
  });

  testWidgets('Save posts one edit op, and undo and redo reverse it', (
    tester,
  ) async {
    final fixture = await _openPane(tester);
    await tester.tapAt(screenFor(tester, _onNote));
    await tester.pump();

    await tester.enterText(
      find.descendant(
        of: find.byType(CanvasNoteEditor),
        matching: find.byType(TextField),
      ),
      'after **bold**',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(CanvasNoteEditor), findsNothing);
    expect(fixture.postedOps, hasLength(1));
    expect(fixture.postedOps.single['kind'], 'edit');
    expect(fixture.postedOps.single['object_id'], 'note');
    expect(fixture.postedOps.single['props'], {'text': 'after **bold**'});
    expect(surfaceDocument(tester).noteTextOf('note'), 'after **bold**');

    await tester.tap(find.bySemanticsLabel('Undo'));
    await tester.pumpAndSettle();
    expect(fixture.postedOps.last['props'], {'text': 'before'});
    expect(surfaceDocument(tester).noteTextOf('note'), 'before');

    await tester.tap(find.bySemanticsLabel('Redo'));
    await tester.pumpAndSettle();
    expect(fixture.postedOps.last['props'], {'text': 'after **bold**'});
    expect(surfaceDocument(tester).noteTextOf('note'), 'after **bold**');
  });

  testWidgets('Escape and Cancel keep the old text and post nothing', (
    tester,
  ) async {
    final fixture = await _openPane(tester);
    await tester.tapAt(screenFor(tester, _onNote));
    await tester.pump();
    await tester.enterText(
      find.descendant(
        of: find.byType(CanvasNoteEditor),
        matching: find.byType(TextField),
      ),
      'changed',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(CanvasNoteEditor), findsNothing);
    expect(fixture.postedOps, isEmpty);
    expect(surfaceDocument(tester).noteTextOf('note'), 'before');
  });

  testWidgets('Backspace while typing never deletes the selected note', (
    tester,
  ) async {
    final fixture = await _openPane(tester);
    await tester.tapAt(screenFor(tester, _onNote));
    await tester.pump();
    await tester.showKeyboard(
      find.descendant(
        of: find.byType(CanvasNoteEditor),
        matching: find.byType(TextField),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(fixture.postedOps, isEmpty);
    expect(surfaceDocument(tester).isAlive('note'), isTrue);
  });

  testWidgets('a right-click menu offers Edit note and opens the editor', (
    tester,
  ) async {
    await _openPane(tester);

    final gesture = await tester.startGesture(
      screenFor(tester, _onNote),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit note'));
    await tester.pumpAndSettle();

    expect(find.byType(CanvasNoteEditor), findsOneWidget);
  });

  testWidgets('a live edit from someone else repaints the note text', (
    tester,
  ) async {
    final fixture = await _openPane(tester);

    fixture.events.add(
      const api.CanvasObjectEdited(
        channelId: 'c1',
        seq: 2,
        opId: 'op-x',
        objectId: 'note',
        props: {'text': 'from afar'},
      ),
    );
    await tester.pump();

    expect(surfaceDocument(tester).noteTextOf('note'), 'from afar');
  });
}
