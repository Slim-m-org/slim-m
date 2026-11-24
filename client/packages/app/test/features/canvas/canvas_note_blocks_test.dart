// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A displayed note renders Markdown blocks, and a note's style props decode without disturbing an older note.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_object_inputs.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_blocks.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_spans.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _style = NoteSpanStyle(
  knownUsernames: {},
  mentionInk: Colors.blue,
  mentionFill: Colors.blueGrey,
  linkInk: Colors.blue,
);
const _base = TextStyle(fontSize: 15);

TextSpan _spans(String text) => buildNoteSpans(text, _base, _style) as TextSpan;

/// Every span in reading order, containers included, so a test can look for one kind of thing.
List<InlineSpan> _all(InlineSpan root) => [
  root,
  if (root is TextSpan)
    for (final child in root.children ?? const <InlineSpan>[]) ..._all(child),
];

String _plain(String text) =>
    _spans(text).toPlainText(includePlaceholders: false);

api.CanvasObject _object(Map<String, dynamic> props) => api.CanvasObject(
  id: 'n',
  kind: 'note',
  zIndex: 1,
  x: 1,
  y: 2,
  w: 330,
  h: 210,
  props: props,
  authorId: 'me',
  seq: 1,
  createdAt: 0,
);

void main() {
  group('Markdown in a note', () {
    test('a heading is larger by the type scale and bold', () {
      final heading = _all(_spans('# big\ntext'))
          .skip(1)
          .whereType<TextSpan>()
          .firstWhere((s) => s.style?.fontSize != null);
      expect(
        heading.style!.fontSize,
        closeTo(15 * AppText.title.fontSize! / AppText.body.fontSize!, 0.01),
      );
      expect(heading.style!.fontWeight, AppWeights.semi);
    });

    test('bullets and numbers get their markers', () {
      expect(_plain('- a\n- b'), contains('• a'));
      expect(_plain('1. a\n2. b'), allOf(contains('1. a'), contains('2. b')));
    });

    test('a quote carries a bar before each line', () {
      expect(_plain('> one\n> two').split('| ').length, 3);
    });

    test('a fenced block is mono and keeps its lines', () {
      final fence = _all(_spans('```\nlet a = 1;\n  b\n```'))
          .whereType<TextSpan>()
          .firstWhere((s) => s.style?.fontFamily == AppFonts.mono);
      expect(fence.text, 'let a = 1;\n  b');
    });

    test('inline strike, code and bold survive inside a block', () {
      final spans = _all(
        _spans('- ~~gone~~ **bold** `code`'),
      ).whereType<TextSpan>();
      expect(
        spans.any((s) => s.style?.decoration == TextDecoration.lineThrough),
        isTrue,
      );
      expect(spans.any((s) => s.style?.fontWeight == AppWeights.semi), isTrue);
      expect(spans.any((s) => s.style?.fontFamily == AppFonts.mono), isTrue);
    });

    test('task items become boxes that remember their state and line', () {
      final marks = _all(_spans('intro\n- [ ] one\n- [x] two'))
          .whereType<WidgetSpan>()
          .map((s) => s.child)
          .whereType<NoteCheckMark>()
          .toList();
      expect(
        [for (final m in marks) (m.checked, m.line)],
        [(false, 1), (true, 2)],
      );
    });

    test('a link is a tappable span, a message link too', () {
      final links = _all(
        _spans('go https://example.com'),
      ).whereType<NoteLinkSpan>();
      expect(links.single.url, 'https://example.com');
    });

    test('plain text stays plain', () {
      expect(_plain('just words'), 'just words');
    });
  });

  group('decoding', () {
    test('a note an older client wrote has the default style', () {
      final input = canvasStrokeInputFrom(
        _object({'text': 'old', 'font_size': 18.0}),
      )!;
      expect(input.noteStyle.isDefault, isTrue);
      expect(input.text, 'old');
      expect(input.fontSize, 18);
    });

    test('a styled note carries its style and a bad prop is ignored', () {
      final input = canvasStrokeInputFrom(
        _object({
          'text': 'new',
          'fill': 'blue',
          'fill_opacity': 0,
          'color': 'auto',
          'size': 'large',
          'unknown': [1],
        }),
      )!;
      expect(input.noteStyle.fill, 'blue');
      expect(input.noteStyle.fillOpacity, 0);
      expect(input.noteStyle.size, 'large');

      final bad = canvasStrokeInputFrom(
        _object({'text': 'x', 'fill': 7, 'fill_opacity': 'lots'}),
      )!;
      expect(bad.noteStyle.isDefault, isTrue);
    });
  });
}
