// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a note's text is laid out: task boxes and links found where they were drawn, and the text left out while it is typed.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_note_layout.dart';
import 'package:slimm_voice_canvas/src/note_label_cache.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_painter_fixtures.dart';

const _base = TextStyle(fontSize: 18, height: noteLineHeight);

InlineSpan _spans() => const TextSpan(
      style: _base,
      children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: NoteCheckMark(checked: true, line: 3),
        ),
        TextSpan(text: ' done  '),
        NoteLinkSpan(url: 'https://example.com', text: 'example'),
      ],
    );

void main() {
  testWidgets('a task box is laid out with its state and source line', (
    tester,
  ) async {
    final painter = layoutNoteText(_spans(), fontSize: 18, width: 300);
    final checks = noteChecksOf(painter);
    expect(checks, hasLength(1));
    expect(checks.single.checked, isTrue);
    expect(checks.single.line, 3);
    expect(checks.single.rect.width, closeTo(18 * noteCheckboxScale, 0.5));
    painter.dispose();
  });

  testWidgets('a link answers only where its glyphs are', (tester) async {
    final painter = layoutNoteText(_spans(), fontSize: 18, width: 300);
    final box = painter
        .getBoxesForSelection(
          const TextSelection(baseOffset: 9, extentOffset: 16),
        )
        .first
        .toRect();
    expect(noteLinkAt(painter, box.center), 'https://example.com');
    expect(noteLinkAt(painter, const Offset(280, 4)), isNull);
    painter.dispose();
  });

  test('the text of the note being typed in is not painted', () {
    CanvasDocument build() => CanvasDocument()
      ..setViewport(const Size(400, 400))
      ..applyPlaced(noteAt())
      ..refresh();
    int labelLayouts(CanvasDocument document) {
      debugResetNoteLabelLayoutCounts();
      StrokePainter(document: document, ink: ink).paint(
        RecordingCanvas(),
        const Size(400, 400),
      );
      return debugNoteLabelLayoutCounts.values.fold(0, (a, b) => a + b);
    }

    final document = build();
    addTearDown(document.dispose);
    expect(labelLayouts(document), 1);
    document.editingObjectId.value = 'note';
    expect(labelLayouts(document), 0);
  });
}
