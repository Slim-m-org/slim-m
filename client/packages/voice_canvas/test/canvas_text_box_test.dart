// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text-box object and tool: the document model, painting, hit testing, and the two gestures that place one.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _text(
  String id, {
  String text = 'hello',
  String size = 'medium',
  String color = 'ink',
  double x = 10,
  double y = 10,
  double w = 200,
  double h = 40,
}) =>
    CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: x,
      y: y,
      w: w,
      h: h,
      points: const [],
      width: 0,
      colorKey: color,
      kind: CanvasObjectKind.text,
      text: text,
      textSize: size,
    );

Future<ui.Image> _render(WidgetTester tester, StrokePainter painter) async {
  late ui.Image image;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Size(300, 100));
    image = await recorder.endRecording().toImage(300, 100);
  });
  return image;
}

Future<bool> _hasPixelNear(
  WidgetTester tester,
  ui.Image image,
  Color color,
) async {
  late ByteData data;
  await tester.runAsync(() async {
    data = (await image.toByteData())!;
  });
  for (var i = 0; i < data.lengthInBytes; i += 4) {
    if ((data.getUint8(i) - (color.r * 255).round()).abs() < 4 &&
        (data.getUint8(i + 1) - (color.g * 255).round()).abs() < 4 &&
        (data.getUint8(i + 2) - (color.b * 255).round()).abs() < 4 &&
        data.getUint8(i + 3) > 200) {
      return true;
    }
  }
  return false;
}

Future<void> _touch(
  WidgetTester tester, {
  required Duration held,
  Offset? dragTo,
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final pointer = TestPointer(1, kind);
  await tester.sendEventToBinding(
    pointer.down(const Offset(60, 60), timeStamp: Duration.zero),
  );
  if (dragTo != null) {
    await tester.sendEventToBinding(pointer.move(dragTo, timeStamp: held));
  }
  await tester.sendEventToBinding(pointer.up(timeStamp: held));
  await tester.pump();
}

void main() {
  group('document', () {
    test('keeps a text box with its size and colour, and counts it', () {
      final document = CanvasDocument()
        ..applyPlaced(_text('t', size: 'large', color: 'blue'));
      addTearDown(document.dispose);
      expect(document.kindOf('t'), CanvasObjectKind.text);
      expect(document.textOf('t'), 'hello');
      expect(document.textBoxOf('t'), (
        text: 'hello',
        size: 'large',
        colorKey: 'blue',
      ));
      expect(document.liveCountsByKind.texts, 1);
    });

    test('setTextBox restyles in place and refuses anything but a text box',
        () {
      final document = CanvasDocument()
        ..applyPlaced(_text('t'))
        ..applyPlaced(
          const CanvasStrokeInput(
            id: 'n',
            seq: 2,
            zIndex: 2,
            x: 0,
            y: 0,
            w: 50,
            h: 50,
            points: [],
            width: 0,
            colorKey: 'note',
            kind: CanvasObjectKind.note,
            text: 'note',
          ),
        );
      addTearDown(document.dispose);
      expect(
        document.setTextBox('t', text: 'bye', size: 'small', colorKey: 'pink'),
        isTrue,
      );
      expect(document.textBoxOf('t'), (
        text: 'bye',
        size: 'small',
        colorKey: 'pink',
      ));
      expect(
        document.setTextBox('n', text: 'x', size: 'small', colorKey: 'pink'),
        isFalse,
      );
      expect(document.textBoxOf('n'), isNull);
    });

    test('a snapshot of the same box brings a remote restyle in', () {
      final document = CanvasDocument()..applyPlaced(_text('t'));
      addTearDown(document.dispose);
      document.applyPlaced(
        _text('t', text: 'again', size: 'small', color: 'green'),
        overwrite: true,
      );
      expect(document.textBoxOf('t'), (
        text: 'again',
        size: 'small',
        colorKey: 'green',
      ));
    });

    test('a click on a text box selects it', () {
      final document = CanvasDocument()
        ..setViewport(const Size(300, 100))
        ..applyPlaced(_text('t'))
        ..refresh();
      addTearDown(document.dispose);
      expect(hitTestTopmost(document, const Offset(50, 20)), 't');
      expect(hitTestTopmost(document, const Offset(280, 90)), isNull);
    });
  });

  group('painting', () {
    testWidgets('draws its glyphs in the box colour', (
      tester,
    ) async {
      final document = CanvasDocument()
        ..setViewport(const Size(300, 100))
        ..applyPlaced(_text('t', color: 'blue'))
        ..refresh();
      addTearDown(document.dispose);
      const blue = Color(0xFF2E6FE0);
      final painter = StrokePainter(
        document: document,
        ink: const Color(0xFF000000),
        inkColors: const {'blue': blue},
      );
      addTearDown(painter.dispose);
      final image = await _render(tester, painter);
      expect(await _hasPixelNear(tester, image, blue), isTrue);
    });

    testWidgets('an unknown colour key paints in the theme ink',
        (tester) async {
      final document = CanvasDocument()
        ..setViewport(const Size(300, 100))
        ..applyPlaced(_text('t', color: 'ink'))
        ..refresh();
      addTearDown(document.dispose);
      const ink = Color(0xFFE86A5C);
      final painter = StrokePainter(document: document, ink: ink);
      addTearDown(painter.dispose);
      expect(await _hasPixelNear(tester, await _render(tester, painter), ink),
          isTrue);
    });

    testWidgets('a recolour repaints instead of reusing the cached layout', (
      tester,
    ) async {
      final document = CanvasDocument()
        ..setViewport(const Size(300, 100))
        ..applyPlaced(_text('t', color: 'blue'))
        ..refresh();
      addTearDown(document.dispose);
      const blue = Color(0xFF2E6FE0);
      const green = Color(0xFF3FA55B);
      final painter = StrokePainter(
        document: document,
        ink: const Color(0xFF000000),
        inkColors: const {'blue': blue, 'green': green},
      );
      addTearDown(painter.dispose);
      await _render(tester, painter);
      document
        ..setTextBox('t', text: 'hello', size: 'medium', colorKey: 'green')
        ..refresh();
      final image = await _render(tester, painter);
      expect(await _hasPixelNear(tester, image, green), isTrue);
      expect(await _hasPixelNear(tester, image, blue), isFalse);
    });

    test('the font steps are three and ascend', () {
      expect(canvasTextFontSizes.keys, ['small', 'medium', 'large']);
      final sizes = canvasTextFontSizes.values.toList();
      expect(sizes, [...sizes]..sort());
      expect(canvasTextFontSizes.containsKey(canvasDefaultTextSize), isTrue);
    });
  });

  group('gestures', () {
    Future<void> pump(
      WidgetTester tester,
      CanvasDocument document, {
      required CanvasTool tool,
      List<Offset>? texts,
      List<Offset>? notes,
      List<Offset>? longPresses,
      List<Offset>? taps,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: tool,
            onStroke: (_) {},
            onTextPlace: texts?.add,
            onNotePlace: notes?.add,
            onSelectLongPress: longPresses?.add,
            onSelectTap: taps == null ? null : (world, _) => taps.add(world),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets(
        'the text tool places once per tap, and the note tool is not called', (
      tester,
    ) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final texts = <Offset>[];
      final notes = <Offset>[];
      await pump(tester, document,
          tool: CanvasTool.text, texts: texts, notes: notes);
      final gesture = await tester.startGesture(const Offset(30, 40));
      expect(texts, isEmpty,
          reason: 'resolved on lift, so a pinch can cancel it');
      await gesture.up();
      await tester.pump();
      expect(texts, [const Offset(30, 40)]);
      expect(notes, isEmpty);
    });

    testWidgets('a second pointer cancels a pending text placement',
        (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final texts = <Offset>[];
      await pump(tester, document, tool: CanvasTool.text, texts: texts);
      final first = await tester.startGesture(const Offset(20, 20));
      final second = await tester.startGesture(const Offset(200, 200));
      await first.up();
      await second.up();
      await tester.pump();
      expect(texts, isEmpty);
    });

    testWidgets(
      'a finger held still on the pan tool reports a long press, not a tap',
      (tester) async {
        final document = CanvasDocument();
        addTearDown(document.dispose);
        final longPresses = <Offset>[];
        final taps = <Offset>[];
        await pump(
          tester,
          document,
          tool: CanvasTool.pan,
          longPresses: longPresses,
          taps: taps,
        );
        await _touch(tester, held: const Duration(milliseconds: 700));
        expect(longPresses, [const Offset(60, 60)]);
        expect(taps, isEmpty);
      },
    );

    testWidgets('a quick tap is a tap and never a long press', (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final longPresses = <Offset>[];
      final taps = <Offset>[];
      await pump(
        tester,
        document,
        tool: CanvasTool.pan,
        longPresses: longPresses,
        taps: taps,
      );
      await _touch(tester, held: const Duration(milliseconds: 80));
      expect(taps, hasLength(1));
      expect(longPresses, isEmpty);
    });

    testWidgets('a held press that drags, or a held mouse, is not a long press',
        (
      tester,
    ) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final longPresses = <Offset>[];
      await pump(
        tester,
        document,
        tool: CanvasTool.pan,
        longPresses: longPresses,
      );
      await _touch(
        tester,
        held: const Duration(milliseconds: 700),
        dragTo: const Offset(160, 60),
      );
      await _touch(
        tester,
        held: const Duration(milliseconds: 700),
        kind: PointerDeviceKind.mouse,
      );
      expect(longPresses, isEmpty);
    });
  });
}
