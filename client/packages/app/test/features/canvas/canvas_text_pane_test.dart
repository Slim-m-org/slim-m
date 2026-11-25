// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text tool through the whole pane: placing a box, a long press on touch, editing in place, and undo and redo.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

import 'canvas_text_pane_support.dart';

Future<void> _longPress(WidgetTester tester, Offset world) async {
  final pointer = TestPointer(7);
  await tester.sendEventToBinding(
    pointer.down(screenFor(tester, world), timeStamp: Duration.zero),
  );
  await tester.sendEventToBinding(
    pointer.up(timeStamp: const Duration(milliseconds: 700)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the text tool opens an editor and sends nothing until it is committed',
    (tester) async {
      final fixture = await openPane(tester);

      await placeWithTool(tester, const Offset(150, 150));
      expect(editor, findsOneWidget);
      expect(fixture.posted, isEmpty);

      await tester.enterText(field, 'hello board');
      await commit(tester);

      final placed = fixture.posted.single;
      expect(placed['kind'], 'text');
      expect(placed['props'], {
        'text': 'hello board',
        'size': 'medium',
        'color': 'ink',
      });
      expect(placed['x'], 150.0);
      expect(placed['y'], 150.0);
      final document = surfaceDocument(tester);
      expect(document.textBoxOf(placed['id'] as String)?.text, 'hello board');
      expect(document.selectedObjectId.value, placed['id']);
    },
  );

  testWidgets('a press outside the editor, on the toolbar, saves the text', (
    tester,
  ) async {
    final fixture = await openPane(tester);

    await placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(field, 'typed then clicked away');
    await tester.tap(find.bySemanticsLabel('Pen'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(editor, findsNothing);
    expect(fixture.posted.single['props']['text'], 'typed then clicked away');
  });

  testWidgets('a press on the field\'s own selection menu keeps editing', (
    tester,
  ) async {
    final fixture = await openPane(tester);

    await placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(field, 'pick a word');
    await tester.longPress(field);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Select all'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(editor, findsOneWidget);
    expect(fixture.posted, isEmpty);
  });

  testWidgets('a press on another text field saves the text', (tester) async {
    const elsewhere = Key('elsewhere');
    final fixture = await openPane(
      tester,
      below: const SizedBox(height: 48, child: TextField(key: elsewhere)),
    );

    await placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(field, 'typed then moved on');
    await tester.tap(find.byKey(elsewhere));
    await tester.pump(const Duration(milliseconds: 400));

    expect(editor, findsNothing);
    expect(fixture.posted.single['props']['text'], 'typed then moved on');
  });

  testWidgets('Escape and an empty box place nothing', (tester) async {
    final fixture = await openPane(tester);

    await placeWithTool(tester, const Offset(150, 150));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    final again = await tester.startGesture(
      screenFor(tester, const Offset(150, 150)),
    );
    await again.up();
    await tester.pumpAndSettle();
    await tester.enterText(field, '   ');
    await commit(tester);

    expect(editor, findsNothing);
    expect(fixture.posted, isEmpty);
  });

  testWidgets('Escape cancels a new text box and puts the tool down', (
    tester,
  ) async {
    final fixture = await openPane(tester);
    await placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(field, 'never sent');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 500));

    expect(field, findsNothing);
    expect(fixture.posted, isEmpty);
    final pan = tester.widget<AppIconButton>(
      find.ancestor(
        of: find.bySemanticsLabel('Pan'),
        matching: find.byWidgetPredicate((w) => w is AppIconButton),
      ),
    );
    expect(pan.active, isTrue, reason: 'one press ends the edit and the tool');
  });

  testWidgets('Ctrl+Enter saves the text box', (tester) async {
    final fixture = await openPane(tester);
    await placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(field, 'keys only');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump(const Duration(milliseconds: 500));

    expect(fixture.posted.single['kind'], 'text');
    expect((fixture.posted.single['props'] as Map)['text'], 'keys only');
  });

  testWidgets('the colour button then the sizes share one row of the bar', (
    tester,
  ) async {
    await openPane(tester);
    await placeWithTool(tester, const Offset(150, 150));

    final small = tester.getCenter(find.text('S'));
    final large = tester.getCenter(find.text('L'));
    final colour = tester.getCenter(find.byTooltip('Text colour'));
    expect(small.dy, closeTo(colour.dy, 0.5));
    expect(large.dy, closeTo(colour.dy, 0.5));
    expect(colour.dx, lessThan(small.dx), reason: 'colour first, then sizes');
  });

  testWidgets('size and colour picked in the editor travel with the text', (
    tester,
  ) async {
    final fixture = await openPane(tester);

    await placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(field, 'big blue');
    await tester.tap(find.text('L'));
    await tester.tap(find.byTooltip('Text colour'));
    await tester.pump();
    await tester.tap(find.byTooltip('Blue'));
    await commit(tester);

    expect(fixture.posted.single['props'], {
      'text': 'big blue',
      'size': 'large',
      'color': 'blue',
    });
  });

  testWidgets('hidden and direction characters never reach the wire', (
    tester,
  ) async {
    final fixture = await openPane(tester);

    await placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(field, 'a\u202Eb\u200Bc\td\r\ne');
    await commit(tester);

    expect((fixture.posted.single['props'] as Map)['text'], 'abc d\ne');
  });

  testWidgets('the text is cut at the server limit', (tester) async {
    final fixture = await openPane(tester);

    await placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(field, 'x' * 600);
    await tester.pump();
    expect(find.text('This text box is full.'), findsOneWidget);
    await commit(tester);

    expect(
      ((fixture.posted.single['props'] as Map)['text'] as String).length,
      500,
    );
  });

  testWidgets('the T key arms the text tool', (tester) async {
    await openPane(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    await tester.pump();
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(150, 150)),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(editor, findsOneWidget);
  });

  testWidgets('a long press on empty canvas with a finger opens the editor', (
    tester,
  ) async {
    final fixture = await openPane(tester);
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    await _longPress(tester, const Offset(150, 150));

    expect(editor, findsOneWidget);
    expect(fixture.posted, isEmpty);
  });

  testWidgets('a long press on an object does not open the text editor', (
    tester,
  ) async {
    await openPane(tester, objects: [canvasNoteJson('note', x: 400)]);
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    await _longPress(tester, const Offset(415, 15));

    expect(editor, findsNothing);
  });

  testWidgets('a refused placement takes the box back off the canvas', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture(placeStatus: 409)..objects = [];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(field, 'doomed');
    await commit(tester);

    expect(fixture.posted, isEmpty);
    expect(surfaceDocument(tester).liveCountsByKind.texts, 0);
    expect(find.text('This canvas is full.'), findsOneWidget);
  });

  testWidgets('a refused edit puts the old text back', (tester) async {
    final fixture = CanvasPaneFixture(opsPostStatus: 400)
      ..objects = [textBoxJson('box')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    await fingerTapTwice(tester, const Offset(415, 20));

    await tester.enterText(field, 'after');
    await commit(tester);

    expect(surfaceDocument(tester).textOf('box'), 'before');
  });

  group('editing a placed box', () {
    Future<CanvasPaneFixture> open(WidgetTester tester) async {
      final fixture = await openPane(tester, objects: [textBoxJson('box')]);
      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();
      return fixture;
    }

    const onBox = Offset(415, 20);

    testWidgets('a second tap opens the editor with the current text', (
      tester,
    ) async {
      await open(tester);

      await fingerTapTwice(tester, onBox);

      expect(editor, findsOneWidget);
      expect(find.text('before'), findsOneWidget);
    });

    testWidgets(
      'committing posts one edit with the whole props; undo and redo reverse it',
      (tester) async {
        final fixture = await open(tester);
        await fingerTapTwice(tester, onBox);

        await tester.enterText(field, 'after');
        await tester.tap(find.text('S'));
        await tester.tap(find.byTooltip('Text colour'));
        await tester.pump();
        await tester.tap(find.byTooltip('Green'));
        await commit(tester);

        final edits = fixture.postedOps.where((op) => op['kind'] == 'edit');
        expect(edits, hasLength(1));
        expect(edits.single['object_id'], 'box');
        expect(edits.single['props'], {
          'text': 'after',
          'size': 'small',
          'color': 'green',
        });
        final document = surfaceDocument(tester);
        expect(document.textBoxOf('box'), (
          text: 'after',
          size: 'small',
          colorKey: 'green',
        ));

        await tester.tap(find.bySemanticsLabel('Undo'));
        await tester.pumpAndSettle();
        expect(
          fixture.postedOps.where((o) => o['kind'] == 'edit').last['props'],
          {'text': 'before', 'size': 'medium', 'color': 'ink'},
        );
        expect(document.textBoxOf('box')?.text, 'before');
        expect(document.textBoxOf('box')?.colorKey, 'ink');

        await tester.tap(find.bySemanticsLabel('Redo'));
        await tester.pumpAndSettle();
        expect(document.textBoxOf('box'), (
          text: 'after',
          size: 'small',
          colorKey: 'green',
        ));
      },
    );

    testWidgets('Escape keeps the old text and posts nothing', (tester) async {
      final fixture = await open(tester);
      await fingerTapTwice(tester, onBox);
      await tester.enterText(field, 'changed');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(editor, findsNothing);
      expect(fixture.postedOps, isEmpty);
      expect(surfaceDocument(tester).textOf('box'), 'before');
    });

    testWidgets('a right-click menu offers Edit text', (tester) async {
      await open(tester);

      final gesture = await tester.startGesture(
        screenFor(tester, onBox),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit text'));
      await tester.pumpAndSettle();

      expect(editor, findsOneWidget);
    });

    testWidgets('a live edit from someone else restyles the box', (
      tester,
    ) async {
      final fixture = await open(tester);

      fixture.events.add(
        const api.CanvasObjectEdited(
          channelId: 'c1',
          seq: 2,
          opId: 'op-x',
          objectId: 'box',
          props: {'text': 'from afar', 'size': 'large', 'color': 'pink'},
        ),
      );
      await tester.pump();

      expect(surfaceDocument(tester).textBoxOf('box'), (
        text: 'from afar',
        size: 'large',
        colorKey: 'pink',
      ));
    });

    testWidgets('a screen reader hears the box by its text', (tester) async {
      await open(tester);
      final handle = tester.ensureSemantics();

      expect(find.bySemanticsLabel(RegExp('Text: before')), findsWidgets);
      handle.dispose();
    });
  });
}
