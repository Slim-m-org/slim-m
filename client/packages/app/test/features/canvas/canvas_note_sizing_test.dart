// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [noteBoxFor]: a note's placed box grows to fit its own text instead of
/// clipping inside a fixed one.
///
/// `noteMaxLines` is not in `slimm_voice_canvas`'s public barrel, so
/// reaching the real function - rather than a copy of its formula - means
/// an `src` import, the same shape `broadcast_bridge.dart` already uses for
/// LiveKit's own unexported `BroadcastManager`.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_note_sheet.dart'
    show maxNoteTextBytes;
import 'package:slimm_app/src/features/canvas/screens/canvas_note_sizing.dart';
// ignore: implementation_imports
import 'package:slimm_voice_canvas/src/canvas_painters.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart' show maxObjectExtent;

void main() {
  testWidgets('a short note keeps the fixed default box', (tester) async {
    final box = noteBoxFor('hello');
    expect(box.width, 220);
    expect(box.height, 140);
  });

  testWidgets('a longer note grows taller than the default, at the same '
      'width', (tester) async {
    final short = noteBoxFor('one short line');
    final long = noteBoxFor(List.filled(40, 'a whole sentence.').join(' '));

    expect(long.width, short.width, reason: 'width never grows for a note');
    expect(
      long.height,
      greaterThan(short.height),
      reason: 'height grows so the extra text is not clipped',
    );
  });

  testWidgets('height clamps at the object extent ceiling every other '
      'canvas object shares, rather than growing without bound', (
    tester,
  ) async {
    final box = noteBoxFor(List.filled(4000, 'word').join(' '));
    expect(box.height, maxObjectExtent);
  });

  testWidgets('empty text still answers the default box, never a zero one', (
    tester,
  ) async {
    final box = noteBoxFor('');
    expect(box.width, 220);
    expect(box.height, 140);
  });

  /// The real property this file exists for: a box [noteBoxFor] sizes must
  /// give the real painter's own [noteMaxLines] enough lines to hold every
  /// line the same text actually wraps to, at every length a note can
  /// legally hold - or the sighted fix ellipsis-truncates the note anyway.
  /// Found failing before the margin in `canvas_note_sizing.dart` was added:
  /// `TextPainter.height` (a real text-shaping result) and a plain division
  /// of it back apart do not agree bit-for-bit, and `floor()` on that
  /// disagreement can land one line short exactly at the boundary this
  /// function sizes to.
  testWidgets(
    'the box always gives the real painter enough lines, at every length a '
    'note can hold, including the byte-cap maximum',
    (tester) async {
      const pad = 8.0;
      const fontSize = 12.0;
      const lineHeightMultiple = 1.3;
      final lineHeight = fontSize * lineHeightMultiple;

      final texts = <String>[
        for (var n = 1; n <= 150; n++)
          List.filled(n, 'a whole sentence right here.').join(' '),
        'x' * (maxNoteTextBytes - 11),
        'nowhitespaceatallareallylongwordthatcannotwrap' * 80,
      ];

      for (final text in texts) {
        final box = noteBoxFor(text);
        final maxLines = noteMaxLines(box.height, lineHeight, pad: pad);
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: const TextStyle(
              fontSize: fontSize,
              height: lineHeightMultiple,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: box.width - pad * 2);
        final actualLines = (painter.height / lineHeight).round();

        expect(
          maxLines,
          greaterThanOrEqualTo(actualLines),
          reason: 'length ${text.length}: boxHeight ${box.height}',
        );
      }
    },
  );
}
