// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Word- and block-level diffing between two message versions, used by
/// `edit_history_sheet.dart` to show what an edit actually changed instead of
/// two versions the reader has to compare by eye.
///
/// Diffing happens in two layers. [diffMessage] first aligns the fenced-code
/// and plain-text blocks `message_fences.dart` already splits a message into,
/// so a fenced code block changes as a whole rather than word by word -
/// diffing source line by line is a different, more specialised job than this
/// sheet takes on, and would fight the code block's own monospace rendering.
/// Within a matched pair of text blocks, [diffWords] then diffs the words.
///
/// A word token is whatever whitespace does not touch, so a `@mention` or a
/// bare URL - both free of internal whitespace - is never split mid-token:
/// it changes wholesale or not at all, never fragmenting into overlapping
/// pieces that would misrender the chip or link it becomes.
library;

import 'message_fences.dart';

/// Which side of a diff a span or block came from.
enum DiffKind { equal, added, removed }

/// One run of text and the side of the diff it belongs to.
class DiffSpan {
  const DiffSpan(this.text, this.kind);
  final String text;
  final DiffKind kind;
}

/// One block of a diffed message: prose with its words marked, or a fenced
/// code block that changed - or did not - as a whole.
sealed class DiffBlock {
  const DiffBlock();
}

class DiffTextBlock extends DiffBlock {
  const DiffTextBlock(this.spans);
  final List<DiffSpan> spans;
}

/// [kind] describes the whole block: a code fence is never partially marked,
/// see the file doc comment for why.
class DiffCodeBlock extends DiffBlock {
  const DiffCodeBlock(this.language, this.code, this.kind);
  final String? language;
  final String code;
  final DiffKind kind;
}

/// Diffs [oldText] against [newText], returning the ordered blocks to render.
/// Every block from both versions appears exactly once.
List<DiffBlock> diffMessage(String oldText, String newText) {
  final a = splitMessageBlocks(oldText);
  final b = splitMessageBlocks(newText);
  final n = a.length;
  final m = b.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = _alignable(a[i], b[j])
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  final blocks = <DiffBlock>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (_alignable(a[i], b[j])) {
      blocks.add(_pairedBlock(a[i], b[j]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      blocks.add(_wholeBlock(a[i], DiffKind.removed));
      i++;
    } else {
      blocks.add(_wholeBlock(b[j], DiffKind.added));
      j++;
    }
  }
  while (i < n) {
    blocks.add(_wholeBlock(a[i], DiffKind.removed));
    i++;
  }
  while (j < m) {
    blocks.add(_wholeBlock(b[j], DiffKind.added));
    j++;
  }
  return blocks;
}

/// A version's own blocks with nothing to compare against - the Original
/// entry, or a lone version. Same shape as a diffed result, entirely
/// [DiffKind.equal].
List<DiffBlock> plainBlocks(String text) => [
  for (final block in splitMessageBlocks(text))
    _wholeBlock(block, DiffKind.equal),
];

/// Whether two blocks can stand in for each other during alignment. Two text
/// blocks always can - their words are diffed separately by [_pairedBlock] -
/// but two code blocks only when they are identical, so a fence that changed
/// at all renders as a whole removal plus a whole addition rather than a
/// partial mark.
bool _alignable(MessageBlock x, MessageBlock y) => switch ((x, y)) {
  (TextBlock(), TextBlock()) => true,
  (CodeBlock a, CodeBlock b) => a.language == b.language && a.code == b.code,
  (_, _) => false,
};

DiffBlock _pairedBlock(MessageBlock oldBlock, MessageBlock newBlock) =>
    switch (newBlock) {
      TextBlock(:final text) => DiffTextBlock(
        diffWords((oldBlock as TextBlock).text, text),
      ),
      CodeBlock(:final language, :final code) => DiffCodeBlock(
        language,
        code,
        DiffKind.equal,
      ),
    };

DiffBlock _wholeBlock(MessageBlock block, DiffKind kind) => switch (block) {
  TextBlock(:final text) => DiffTextBlock([DiffSpan(text, kind)]),
  CodeBlock(:final language, :final code) => DiffCodeBlock(
    language,
    code,
    kind,
  ),
};

final RegExp _tokenPattern = RegExp(r'\s+|\S+');

/// Diffs [oldText] against [newText] word by word (see the file doc comment
/// for what counts as a word), merging adjacent same-side tokens into one
/// span so a run of several added words is one span, not one per word.
List<DiffSpan> diffWords(String oldText, String newText) {
  final a = _tokenPattern.allMatches(oldText).map((m) => m[0]!).toList();
  final b = _tokenPattern.allMatches(newText).map((m) => m[0]!).toList();
  // An edit is usually a small change in a big message; only the middle needs the quadratic table.
  var head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  var tail = 0;
  while (tail < a.length - head &&
      tail < b.length - head &&
      a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final spans = <DiffSpan>[];
  for (var k = 0; k < head; k++) {
    _push(spans, a[k], DiffKind.equal);
  }
  _diffMiddle(
    spans,
    a.sublist(head, a.length - tail),
    b.sublist(head, b.length - tail),
  );
  for (var k = a.length - tail; k < a.length; k++) {
    _push(spans, a[k], DiffKind.equal);
  }
  return spans;
}

void _diffMiddle(List<DiffSpan> spans, List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      _push(spans, a[i], DiffKind.equal);
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      _push(spans, a[i], DiffKind.removed);
      i++;
    } else {
      _push(spans, b[j], DiffKind.added);
      j++;
    }
  }
  while (i < n) {
    _push(spans, a[i], DiffKind.removed);
    i++;
  }
  while (j < m) {
    _push(spans, b[j], DiffKind.added);
    j++;
  }
}

void _push(List<DiffSpan> spans, String text, DiffKind kind) {
  if (spans.isNotEmpty && spans.last.kind == kind) {
    spans[spans.length - 1] = DiffSpan(spans.last.text + text, kind);
  } else {
    spans.add(DiffSpan(text, kind));
  }
}
