// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A one-word edit in a long message must not pay for a table over the whole
/// message: `diffWords` ran on the UI thread inside the history sheet's build.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/edit_history_diff.dart';

void main() {
  test('a one-word edit in a long message is diffed in a blink', () {
    final words = [for (var i = 0; i < 4000; i++) 'w${i % 97}'];
    final oldText = words.join(' ');
    final edited = [...words]..[2000] = 'EDITED';
    final newText = edited.join(' ');

    final watch = Stopwatch()..start();
    final spans = diffWords(oldText, newText);
    watch.stop();

    expect(watch.elapsedMilliseconds, lessThan(200));
    expect(
      spans.where((s) => s.kind != DiffKind.equal).map((s) => s.text).toList(),
      ['w${2000 % 97}', 'EDITED'],
    );
  });

  test('trimming the shared head and tail keeps whole-message equality', () {
    final spans = diffWords('a b c d e', 'a b X d e');
    expect(spans.map((s) => s.text).join(), contains('a b '));
    expect(spans.where((s) => s.kind == DiffKind.added).single.text, 'X');
    expect(spans.where((s) => s.kind == DiffKind.removed).single.text, 'c');
  });
}
