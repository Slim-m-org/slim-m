// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text tool through the whole pane: placing a box, a long press on touch, editing in place, and undo and redo.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/canvas_text_editor.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

Map<String, dynamic> _textJson(String id, {String authorId = 'me'}) => {
  'id': id,
  'kind': 'text',
  'z_index': 1,
  'x': 400.0,
  'y': 10.0,
  'w': 240.0,
  'h': 34.0,
  'props': {'text': 'before', 'size': 'medium', 'color': 'ink'},
  'author_id': authorId,
  'seq': 1,
  'created_at': 0,
};

Future<CanvasPaneFixture> _openPane(
  WidgetTester tester, {
  List<Map<String, dynamic>> objects = const [],
}) async {
  final fixture = CanvasPaneFixture()..objects = [...objects];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await tester.pumpAndSettle();
  return fixture;
}

Finder get _field => find.descendant(
  of: find.byType(CanvasTextEditor),
  matching: find.byType(TextField),
);

Future<void> _placeWithTool(WidgetTester tester, Offset world) async {
  await tester.tap(find.bySemanticsLabel('Text'));
  await tester.pump();
  final gesture = await tester.startGesture(screenFor(tester, world));
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _fingerTapTwice(WidgetTester tester, Offset world) async {
  final at = screenFor(tester, world);
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tapAt(at);
  await tester.pumpAndSettle();
}

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
  testWidgets('the text tool opens an editor and sends nothing until Save', (
    tester,
  ) async {
    final fixture = await _openPane(tester);

    await _placeWithTool(tester, const Offset(150, 150));
    expect(find.byType(CanvasTextEditor), findsOneWidget);
    expect(fixture.posted, isEmpty);

    await tester.enterText(_field, 'hello board');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

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
  });

  testWidgets('Cancel and an empty box place nothing', (tester) async {
    final fixture = await _openPane(tester);

    await _placeWithTool(tester, const Offset(150, 150));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    final again = await tester.startGesture(
      screenFor(tester, const Offset(150, 150)),
    );
    await again.up();
    await tester.pumpAndSettle();
    await tester.enterText(_field, '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(CanvasTextEditor), findsNothing);
    expect(fixture.posted, isEmpty);
  });

  testWidgets('size and colour picked in the editor travel with the text', (
    tester,
  ) async {
    final fixture = await _openPane(tester);

    await _placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(_field, 'big blue');
    await tester.tap(find.bySemanticsLabel('Large text'));
    await tester.tap(find.bySemanticsLabel('Blue'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(fixture.posted.single['props'], {
      'text': 'big blue',
      'size': 'large',
      'color': 'blue',
    });
  });

  testWidgets('hidden and direction characters never reach the wire', (
    tester,
  ) async {
    final fixture = await _openPane(tester);

    await _placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(_field, 'a‮b​c\td\r\ne');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((fixture.posted.single['props'] as Map)['text'], 'abc d\ne');
  });

  testWidgets('the text is cut at the server limit', (tester) async {
    final fixture = await _openPane(tester);

    await _placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(_field, 'x' * 600);
    await tester.pump();
    expect(find.text('This text box is full.'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      ((fixture.posted.single['props'] as Map)['text'] as String).length,
      500,
    );
  });

  testWidgets('the T key arms the text tool', (tester) async {
    await _openPane(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(150, 150)),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(CanvasTextEditor), findsOneWidget);
  });

  testWidgets('a long press on empty canvas with a finger opens the editor', (
    tester,
  ) async {
    final fixture = await _openPane(tester);
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    await _longPress(tester, const Offset(150, 150));

    expect(find.byType(CanvasTextEditor), findsOneWidget);
    expect(fixture.posted, isEmpty);
  });

  testWidgets('a long press on an object does not open the text editor', (
    tester,
  ) async {
    await _openPane(tester, objects: [canvasNoteJson('note', x: 400)]);
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    await _longPress(tester, const Offset(415, 15));

    expect(find.byType(CanvasTextEditor), findsNothing);
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

    await _placeWithTool(tester, const Offset(150, 150));
    await tester.enterText(_field, 'doomed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(fixture.posted, isEmpty);
    expect(surfaceDocument(tester).liveCountsByKind.texts, 0);
    expect(find.text('This canvas is full.'), findsOneWidget);
  });

  testWidgets('a refused edit puts the old text back', (tester) async {
    final fixture = CanvasPaneFixture(opsPostStatus: 400)
      ..objects = [_textJson('box')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    await _fingerTapTwice(tester, const Offset(415, 20));

    await tester.enterText(_field, 'after');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(surfaceDocument(tester).textOf('box'), 'before');
  });

  group('editing a placed box', () {
    Future<CanvasPaneFixture> open(WidgetTester tester) async {
      final fixture = await _openPane(tester, objects: [_textJson('box')]);
      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();
      return fixture;
    }

    const onBox = Offset(415, 20);

    testWidgets('a second tap opens the editor with the current text', (
      tester,
    ) async {
      await open(tester);

      await _fingerTapTwice(tester, onBox);

      expect(find.byType(CanvasTextEditor), findsOneWidget);
      expect(find.text('before'), findsOneWidget);
    });

    testWidgets(
      'Save posts one edit with the whole props; undo and redo reverse it',
      (tester) async {
        final fixture = await open(tester);
        await _fingerTapTwice(tester, onBox);

        await tester.enterText(_field, 'after');
        await tester.tap(find.bySemanticsLabel('Small text'));
        await tester.tap(find.bySemanticsLabel('Green'));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

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
      await _fingerTapTwice(tester, onBox);
      await tester.enterText(_field, 'changed');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(CanvasTextEditor), findsNothing);
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

      expect(find.byType(CanvasTextEditor), findsOneWidget);
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
