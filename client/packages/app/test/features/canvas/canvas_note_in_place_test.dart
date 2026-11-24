// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note typed in where it sits: the field is the note's own rect at every zoom, a tap outside commits,
/// a draft sends nothing until it is committed, and the style bar and task boxes each send one edit.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart' show AppIconButton;
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_blocks.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_limits.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_spans.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_selection_bar.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

/// The reference note box, whose text is 18 world units tall: readable at zoom 1.
Map<String, dynamic> _note({
  String text = 'before',
  String authorId = 'me',
  Map<String, Object?> props = const {},
}) => {
  ...canvasNoteJson('note', x: 100, authorId: authorId, text: text),
  'y': 100.0,
  'w': 330.0,
  'h': 210.0,
  'props': {'text': text, ...props},
};

const _onNote = Offset(300, 200);
const _empty = Offset(700, 500);
final _barEmoji = find.byWidgetPredicate(
  (w) => w is AppIconButton && w.semanticLabel == 'Insert emoji',
);
final _editorRect = find.byKey(const ValueKey('canvas-note-editor-rect'));

Future<CanvasPaneFixture> _pane(
  WidgetTester tester, {
  Map<String, dynamic>? note,
  int placeStatus = 201,
  int opsStatus = 201,
  String? tool,
  bool noteStyle = true,
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture(
    placeStatus: placeStatus,
    opsPostStatus: opsStatus,
  )..objects = [?note];
  if (!noteStyle) {
    fixture.routes = (request) async => request.url.path == '/version'
        ? jsonResponse({
            'name': 'slim-m',
            'version': '0.118.0',
            'protocol': 1,
            'push_enabled': false,
            'invite_required': false,
            'claimed': true,
          })
        : null;
  }
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, tool: tool);
  await pumpFrames(tester);
  if (tool == null) {
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
  }
  return fixture;
}

Future<void> _click(WidgetTester tester, Offset world) async {
  final camera = surfaceDocument(tester).camera;
  final gesture = await tester.startGesture(
    screenFor(
      tester,
      Offset(
        (world.dx - camera.x) * camera.zoom,
        (world.dy - camera.y) * camera.zoom,
      ),
    ),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 120));
}

Future<void> _openEditor(WidgetTester tester) async {
  await _click(tester, _onNote);
  await _click(tester, _onNote);
  await pumpFrames(tester, frames: 15);
  expect(_editorRect, findsOneWidget);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(
    find.descendant(
      of: _editorRect,
      matching: find.byWidgetPredicate((w) => w is EditableText),
    ),
    text,
  );
  await tester.pump();
}

Future<void> _commitWithKeys(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await pumpFrames(tester);
}

Rect _noteRectOnScreen(WidgetTester tester) {
  final document = surfaceDocument(tester);
  final bounds = document.objectBounds('note')!;
  final camera = document.camera;
  return Rect.fromLTWH(
    (bounds.x - camera.x) * camera.zoom,
    (bounds.y - camera.y) * camera.zoom,
    bounds.w * camera.zoom,
    bounds.h * camera.zoom,
  ).shift(tester.getTopLeft(find.byWidgetPredicate((w) => w is CanvasSurface)));
}

void main() {
  group('the field is the note', () {
    for (final zoom in [0.5, 1.0, 2.0]) {
      testWidgets('its rect equals the note rect at zoom $zoom', (
        tester,
      ) async {
        await _pane(tester, note: _note());
        final document = surfaceDocument(tester)..setCamera(Camera(zoom: zoom));
        await tester.pump();
        await _openEditor(tester);
        await pumpFrames(tester, frames: 20);

        expect(document.editingObjectId.value, 'note');
        expect(tester.getRect(_editorRect), _noteRectOnScreen(tester));
      });
    }

    testWidgets('a note too small to read eases the camera up to body text', (
      tester,
    ) async {
      await _pane(tester, note: _note());
      final document = surfaceDocument(tester)
        ..setCamera(const Camera(zoom: 0.5));
      await tester.pump();
      await _openEditor(tester);
      await pumpFrames(tester, frames: 30);

      final screenFont = noteFontSizeFor(330, 210) * document.camera.zoom;
      expect(screenFont, greaterThanOrEqualTo(15 - 0.01));
    });

    testWidgets('it follows a remote move of the note', (tester) async {
      await _pane(tester, note: _note());
      await _openEditor(tester);

      surfaceDocument(tester)
        ..moveObject('note', 160, 140, 330, 210)
        ..refresh();
      await tester.pump();

      expect(tester.getRect(_editorRect), _noteRectOnScreen(tester));
    });

    testWidgets('the note grows with the text typed and never shrinks', (
      tester,
    ) async {
      await _pane(tester, note: _note());
      await _openEditor(tester);
      final before = surfaceDocument(tester).objectBounds('note')!.h;

      await _type(tester, List.filled(40, 'a long line of words').join('\n'));
      final grown = surfaceDocument(tester).objectBounds('note')!.h;
      expect(grown, greaterThan(before));

      await _type(tester, 'short');
      expect(surfaceDocument(tester).objectBounds('note')!.h, grown);
    });
  });

  group('committing', () {
    testWidgets('a tap outside commits one edit', (tester) async {
      final fixture = await _pane(tester, note: _note());
      await _openEditor(tester);
      await _type(tester, 'after');

      await _click(tester, _empty);
      await pumpFrames(tester);

      expect(_editorRect, findsNothing);
      final edits = fixture.postedOps.where((op) => op['kind'] == 'edit');
      expect(edits, hasLength(1));
      expect((edits.single['props'] as Map)['text'], 'after');
    });

    testWidgets('Escape cancels and restores the box', (tester) async {
      final fixture = await _pane(tester, note: _note());
      await _openEditor(tester);
      await _type(tester, List.filled(40, 'a long line of words').join('\n'));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpFrames(tester);

      expect(fixture.postedOps, isEmpty);
      expect(surfaceDocument(tester).objectBounds('note')!.h, 210);
      expect(surfaceDocument(tester).editingObjectId.value, isNull);
    });

    testWidgets('a lock during the edit keeps the field open', (tester) async {
      await _pane(tester, note: _note(), opsStatus: 409);
      await _openEditor(tester);
      await _type(tester, 'after');

      await _commitWithKeys(tester);

      expect(_editorRect, findsOneWidget);
    });
  });

  group('a draft note', () {
    Future<void> placeWithNoteTool(WidgetTester tester) async {
      await tester.tap(find.bySemanticsLabel('Note'));
      await tester.pump();
      await _click(tester, _onNote);
      await pumpFrames(tester, frames: 15);
    }

    testWidgets('sends nothing until it is committed', (tester) async {
      final fixture = await _pane(tester, tool: 'Pen');
      await placeWithNoteTool(tester);

      expect(_editorRect, findsOneWidget);
      await _type(tester, 'typed');
      expect(fixture.posted, isEmpty);

      await _commitWithKeys(tester);
      await pumpFrames(tester);
      expect(fixture.posted, hasLength(1));
      expect(fixture.posted.single['kind'], 'note');
      expect((fixture.posted.single['props'] as Map)['text'], 'typed');
    });

    testWidgets('Escape discards it', (tester) async {
      final fixture = await _pane(tester, tool: 'Pen');
      await placeWithNoteTool(tester);
      await _type(tester, 'typed');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpFrames(tester);

      expect(_editorRect, findsNothing);
      expect(fixture.posted, isEmpty);
      expect(surfaceDocument(tester).objectCount.value, 0);
    });

    testWidgets('a refused place keeps the typed text in an open draft', (
      tester,
    ) async {
      final fixture = await _pane(tester, tool: 'Pen', placeStatus: 403);
      await placeWithNoteTool(tester);
      await _type(tester, 'typed');

      await _commitWithKeys(tester);
      await pumpFrames(tester, frames: 30);

      expect(fixture.posted, isEmpty);
      expect(_editorRect, findsOneWidget);
      expect(find.text('typed'), findsOneWidget);
    });
  });

  group('the style bar', () {
    testWidgets('shows over a selected note and one tap sends one edit', (
      tester,
    ) async {
      final fixture = await _pane(tester, note: _note());
      await _click(tester, _onNote);
      expect(
        find.byWidgetPredicate((w) => w is CanvasSelectionBar),
        findsOneWidget,
      );

      await tester.tap(find.text('Solid'));
      await pumpFrames(tester);

      final edits = fixture.postedOps.where((op) => op['kind'] == 'edit');
      expect(edits, hasLength(1));
      expect(edits.single['props'], {'fill_opacity': 1});
      expect(surfaceDocument(tester).noteStyleOf('note')!.fillOpacity, 1);
    });

    testWidgets('offers the amber fill once', (tester) async {
      await _pane(tester, note: _note());
      await _click(tester, _onNote);

      expect(find.bySemanticsLabel('Default fill'), findsOneWidget);
      // The text colour row keeps its own amber.
      expect(find.bySemanticsLabel('Amber'), findsOneWidget);
    });

    testWidgets('a server that replaces edit props gets no style bar', (
      tester,
    ) async {
      await _pane(tester, note: _note(), noteStyle: false);
      await _click(tester, _onNote);
      expect(
        find.byWidgetPredicate((w) => w is CanvasSelectionBar),
        findsNothing,
      );
    });

    testWidgets('undo puts the old style back with one more edit', (
      tester,
    ) async {
      final fixture = await _pane(tester, note: _note());
      await _click(tester, _onNote);
      await tester.tap(find.text('Clear'));
      await pumpFrames(tester);

      await tester.tap(find.bySemanticsLabel('Undo'));
      await pumpFrames(tester);

      expect(
        fixture.postedOps.where((op) => op['kind'] == 'edit'),
        hasLength(2),
      );
      expect((fixture.postedOps.last['props'] as Map)['fill_opacity'], isNull);
      expect(surfaceDocument(tester).noteStyleOf('note')!.fillOpacity, isNull);
    });

    testWidgets("someone else's note shows no bar to a plain member", (
      tester,
    ) async {
      await _pane(tester, note: _note(authorId: 'other'));
      await _click(tester, _onNote);

      expect(
        find.byWidgetPredicate((w) => w is CanvasSelectionBar),
        findsNothing,
      );
    });
  });

  group('the bar emoji button', () {
    Future<TextEditingController> openCompact(
      WidgetTester tester,
      String text,
    ) async {
      await _pane(
        tester,
        note: _note(text: text),
        size: const Size(390, 800),
      );
      await _openEditor(tester);
      return tester
          .widget<EditableText>(
            find.descendant(
              of: _editorRect,
              matching: find.byWidgetPredicate((w) => w is EditableText),
            ),
          )
          .controller;
    }

    testWidgets('on a phone opens a sheet and inserts what is picked', (
      tester,
    ) async {
      final controller = await openCompact(tester, 'hi');

      await tester.tap(_barEmoji);
      await pumpFrames(tester, frames: 30);
      await tester.tap(find.text('\u{1F600}').first);
      await pumpFrames(tester, frames: 30);

      expect(controller.text, contains('\u{1F600}'));
      expect(_editorRect, findsOneWidget);
    });

    testWidgets('says the note is full when an emoji does not fit', (
      tester,
    ) async {
      final controller = await openCompact(tester, 'a' * 3986);
      expect(noteWireBytes(controller.text), lessThanOrEqualTo(4000));

      await tester.tap(_barEmoji);
      await pumpFrames(tester, frames: 30);
      await tester.tap(find.text('\u{1F600}').first);
      await pumpFrames(tester, frames: 30);

      expect(controller.text, 'a' * 3986);
      expect(find.text(noteFullSentence), findsOneWidget);
    });
  });

  group('links', () {
    const text = 'https://example.com';
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');

    Offset linkAt(WidgetTester tester) {
      final bounds = surfaceDocument(tester).objectBounds('note')!;
      final painter = layoutNoteText(
        buildNoteSpans(text, const TextStyle(), _spanStyle),
        fontSize: noteTextSizeOf(
          noteFontSizeFor(bounds.w, bounds.h),
          const CanvasNoteStyle(),
        ),
        width: bounds.w - noteWorldPad * 2,
      );
      final rect = painter
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 5),
          )
          .first
          .toRect();
      return Offset(bounds.x + noteWorldPad, bounds.y + noteWorldPad) +
          rect.center;
    }

    testWidgets('a first click selects the note and a click on it opens', (
      tester,
    ) async {
      final launched = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(launcher, (
        call,
      ) async {
        launched.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          launcher,
          null,
        ),
      );
      await _pane(tester, note: _note(text: text));

      await _click(tester, linkAt(tester));
      expect(surfaceDocument(tester).selectedObjectId.value, 'note');
      expect(launched.where((c) => c.method == 'launch'), isEmpty);

      await tester.pump(const Duration(seconds: 1));
      await _click(tester, linkAt(tester));
      expect(launched.where((c) => c.method == 'launch'), hasLength(1));
    });
  });

  group('task boxes', () {
    const text = '- [ ] one\n- [x] two';

    Offset boxOf(WidgetTester tester, int index) {
      final document = surfaceDocument(tester);
      final bounds = document.objectBounds('note')!;
      final painter = layoutNoteText(
        buildNoteSpans(text, const TextStyle(), _spanStyle),
        fontSize: noteTextSizeOf(
          noteFontSizeFor(bounds.w, bounds.h),
          const CanvasNoteStyle(),
        ),
        width: bounds.w - noteWorldPad * 2,
      );
      final rect = noteChecksOf(painter)[index].rect;
      return Offset(bounds.x + noteWorldPad, bounds.y + noteWorldPad) +
          rect.center;
    }

    testWidgets('ticking a box sends one edit with that line rewritten', (
      tester,
    ) async {
      final fixture = await _pane(tester, note: _note(text: text));

      await _click(tester, boxOf(tester, 0));
      await pumpFrames(tester);

      final edits = fixture.postedOps.where((op) => op['kind'] == 'edit');
      expect(edits, hasLength(1));
      expect((edits.single['props'] as Map)['text'], '- [x] one\n- [x] two');
      expect(_editorRect, findsNothing);
    });

    testWidgets('a person who may not edit the note ticks nothing', (
      tester,
    ) async {
      final fixture = await _pane(
        tester,
        note: _note(text: text, authorId: 'other'),
      );

      await _click(tester, boxOf(tester, 0));
      await pumpFrames(tester);

      expect(fixture.postedOps, isEmpty);
    });
  });

  test('toggling flips only the named line', () {
    expect(toggleNoteTask('- [ ] a\n- [x] b', 1), '- [ ] a\n- [ ] b');
    expect(toggleNoteTask('- [ ] a', 0), '- [x] a');
    expect(toggleNoteTask('plain', 0), isNull);
    expect(toggleNoteTask('- [ ] a', 4), isNull);
  });

  test('a link is found where it is drawn', () {
    final painter = layoutNoteText(
      buildNoteSpans(
        'see https://example.com now',
        const TextStyle(fontSize: 18),
        _spanStyle,
      ),
      fontSize: 18,
      width: 600,
    );
    final box = painter
        .getBoxesForSelection(
          const TextSelection(baseOffset: 6, extentOffset: 12),
        )
        .first
        .toRect();
    expect(noteLinkAt(painter, box.center), 'https://example.com');
    expect(noteLinkAt(painter, const Offset(590, 5)), isNull);
  });
}

const _spanStyle = NoteSpanStyle(
  knownUsernames: {},
  mentionInk: Colors.blue,
  mentionFill: Colors.blueGrey,
  linkInk: Colors.blue,
);
