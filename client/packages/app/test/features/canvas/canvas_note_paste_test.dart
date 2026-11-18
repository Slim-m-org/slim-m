// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A paste past a note's limit keeps as much of itself as fits, cut between
/// characters, and the note then says how much it holds.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_limits.dart';

TextEditingValue _paste(String before, String after, {VoidCallback? onCut}) =>
    NoteByteLimitFormatter(onRefused: onCut).formatEditUpdate(
      TextEditingValue(text: before),
      TextEditingValue(text: after),
    );

void main() {
  test('a long paste at the end keeps what fits', () {
    var cut = 0;
    final kept = _paste('hello ', 'hello ${'x' * 9000}', onCut: () => cut++);

    expect(kept.text, startsWith('hello xxx'));
    expect(noteWireBytes(kept.text), lessThanOrEqualTo(maxNoteTextBytes));
    expect(noteWireBytes('${kept.text}x'), greaterThan(maxNoteTextBytes));
    expect(kept.selection.baseOffset, kept.text.length);
    expect(cut, 1);
  });

  test('a paste in the middle keeps the text after it', () {
    final kept = _paste('start end', 'start ${'y' * 9000}end');

    expect(kept.text, startsWith('start yyy'));
    expect(kept.text, endsWith('yend'));
    expect(kept.selection.baseOffset, kept.text.length - 'end'.length);
  });

  test('emoji are cut whole, never mid-sequence', () {
    const family =
        '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}';
    final kept = _paste('', family * 400);

    expect(kept.text.length % family.length, 0);
    expect(noteWireBytes(kept.text), lessThanOrEqualTo(maxNoteTextBytes));
  });

  test('a full note takes nothing more', () {
    final full = 'a' * (maxNoteTextBytes - 11);
    final kept = _paste(full, '${full}b');
    expect(kept.text, full);
  });

  test('the full sentence names the size', () {
    expect(noteFullSentence, contains('4,000 characters'));
  });
}
