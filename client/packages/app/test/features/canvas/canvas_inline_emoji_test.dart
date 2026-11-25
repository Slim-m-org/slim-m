// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A completed custom `:name:` in a note or a text box is its emoji in place: no preview line, the stored text stays the shortcode, and an unknown name stays text.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_note_emoji_images.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_blocks.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_spans.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_text_spans.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';
import 'canvas_text_pane_support.dart' show textBoxJson;

final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

final _emoji = [
  const api.CustomEmoji(
    id: 'e-blobby',
    name: 'blobby',
    uploaderId: 'u',
    createdAt: 1,
  ),
];

NoteSpanStyle _style({
  Map<String, String> emoji = const {'blobby': 'e-blobby'},
}) => NoteSpanStyle(
  knownUsernames: const {},
  mentionInk: Colors.blue,
  mentionFill: Colors.blue,
  linkInk: Colors.blue,
  customEmoji: emoji,
);

final _editorRect = find.byKey(const ValueKey('canvas-note-editor-rect'));
final _typedText = find.descendant(
  of: _editorRect,
  matching: find.byWidgetPredicate((w) => w is EditableText),
);
final _emojiTile = find.descendant(
  of: _typedText,
  matching: find.byWidgetPredicate((w) => w is CustomEmojiImage),
);

Map<String, dynamic> _note(String text) => {
  ...canvasNoteJson('note', x: 100, authorId: 'me', text: text),
  'y': 100.0,
  'w': 330.0,
  'h': 210.0,
  'props': {'text': text},
};

Future<CanvasPaneFixture> _pane(
  WidgetTester tester, {
  required Map<String, dynamic> object,
  double width = 1280,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture()..objects = [object];
  final container = fixture.container(
    extraOverrides: [
      customEmojiProvider.overrideWith((ref) => _emoji),
      customEmojiImageProvider.overrideWith((ref, id) => _png),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await pumpFrames(tester);
  await tester.tap(find.bySemanticsLabel('Pan'));
  await tester.pump();
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

Future<EditableText> _openAndType(WidgetTester tester, String text) async {
  await _click(tester, const Offset(300, 200));
  await _click(tester, const Offset(300, 200));
  await pumpFrames(tester, frames: 15);
  final field = find.descendant(
    of: _editorRect,
    matching: find.byWidgetPredicate((w) => w is EditableText),
  );
  await tester.enterText(field, text);
  await pumpFrames(tester, frames: 5);
  return tester.widget<EditableText>(field);
}

/// Lets the engine decode an image, which fake async never waits for.
Future<void> _decode(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await pumpFrames(tester, frames: 5);
}

Future<void> _commitWithKeys(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await pumpFrames(tester);
}

void main() {
  group('typing in a note', () {
    testWidgets('a completed custom name is the emoji, with no preview line', (
      tester,
    ) async {
      await _pane(tester, object: _note('before'));
      final field = await _openAndType(tester, 'hi :blobby: there');

      expect(_emojiTile, findsOneWidget);
      expect(find.byKey(const Key('composer-shortcode-preview')), findsNothing);
      expect(field.controller.text, 'hi :blobby: there');
      final tile = tester.getRect(_emojiTile);
      final font = field.style.fontSize!;
      expect(tile.width, closeTo(font * noteEmojiScale, 0.5));
      expect(tile.height, closeTo(font * noteEmojiScale, 0.5));
    });

    testWidgets('an unknown name stays text', (tester) async {
      await _pane(tester, object: _note('before'));
      final field = await _openAndType(tester, 'hi :nope: there');

      expect(_emojiTile, findsNothing);
      expect(field.controller.text, 'hi :nope: there');
    });

    testWidgets('an unfinished name is not an emoji yet', (tester) async {
      await _pane(tester, object: _note('before'));
      await _openAndType(tester, 'hi :blobby');
      expect(_emojiTile, findsNothing);
    });

    testWidgets('the text after the emoji keeps its place on the line', (
      tester,
    ) async {
      await _pane(tester, object: _note('before'));
      await _openAndType(tester, ':blobby:x');

      final tile = tester.getRect(_emojiTile);
      final box = tester.state<EditableTextState>(_typedText).renderEditable;
      final after = box.getLocalRectForCaret(const TextPosition(offset: 8));
      final afterGlobal = box.localToGlobal(after.topLeft);
      expect(afterGlobal.dx - tile.right, lessThan(4));
    });

    testWidgets('commit stores the lowercase shortcode', (tester) async {
      final fixture = await _pane(tester, object: _note('before'));
      await _openAndType(tester, 'a :Blobby: b');
      await _commitWithKeys(tester);

      final edits = fixture.postedOps.where((op) => op['kind'] == 'edit');
      expect((edits.single['props'] as Map)['text'], 'a :blobby: b');
    });
  });

  group('a note on the board', () {
    test('the shortcode lays out as one emoji box', () {
      final painter = layoutNoteText(
        buildNoteSpans('a :blobby: b', const TextStyle(), _style()),
        fontSize: 12,
        width: 300,
      );
      final emojis = noteEmojisOf(painter);
      expect(emojis, hasLength(1));
      expect(emojis.single.rect.width, closeTo(12 * noteEmojiScale, 0.01));
      expect(emojis.single.rect.height, closeTo(12 * noteEmojiScale, 0.01));
    });

    test('an unknown name lays out as text', () {
      final painter = layoutNoteText(
        buildNoteSpans('a :nope: b', const TextStyle(), _style()),
        fontSize: 12,
        width: 300,
      );
      expect(noteEmojisOf(painter), isEmpty);
    });

    test('a text box lays out its shortcode as an emoji too', () {
      final painter = layoutNoteText(
        buildTextBoxSpans(':blobby:', const TextStyle(), _style()),
        fontSize: 20,
        width: 300,
      );
      expect(noteEmojisOf(painter).single.rect.width, closeTo(24, 0.01));
      expect(
        noteEmojisOf(
          layoutNoteText(
            buildTextBoxSpans(':nope:', const TextStyle(), _style()),
            fontSize: 20,
            width: 300,
          ),
        ),
        isEmpty,
      );
    });

    testWidgets('the pane loads the bitmap of an emoji a note names', (
      tester,
    ) async {
      await _pane(tester, object: _note('hi :blobby:'));
      await _decode(tester);
      final scope = ProviderScope.containerOf(
        tester.element(find.byWidgetPredicate((w) => w is CanvasSurface)),
      );
      expect(scope.read(canvasNoteEmojiImagesProvider), contains('e-blobby'));
    });

    testWidgets('a text box asks for the bitmap too', (tester) async {
      await _pane(
        tester,
        object: {
          ...textBoxJson('box'),
          'props': {'text': ':blobby:', 'size': 'medium', 'color': 'ink'},
        },
      );
      await _decode(tester);
      final scope = ProviderScope.containerOf(
        tester.element(find.byWidgetPredicate((w) => w is CanvasSurface)),
      );
      expect(scope.read(canvasNoteEmojiImagesProvider), contains('e-blobby'));
    });
  });
}
