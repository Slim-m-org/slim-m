// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Splitting a message body into plain-text and fenced-code blocks.
///
/// A fence marker must occupy its whole line (only the backticks and an
/// optional language token, nothing else) so an inline `` `run``` `` of
/// backticks inside ordinary prose is never mistaken for one: inline code
/// lives inside a line, a fence always starts and ends one.
library;

final RegExp _fenceOpen = RegExp(r'^```([A-Za-z0-9_+#-]*)\s*$');
final RegExp _fenceClose = RegExp(r'^```\s*$');

/// One piece of a message: either running text or a fenced code block.
sealed class MessageBlock {
  const MessageBlock();
}

class TextBlock extends MessageBlock {
  const TextBlock(this.text);
  final String text;
}

/// [language] is the raw fence token, un-normalised, or null for an
/// unlabelled fence (` ``` ` with nothing after it).
class CodeBlock extends MessageBlock {
  const CodeBlock(this.language, this.code);
  final String? language;
  final String code;
}

/// Splits [content] on fenced code. An opening fence with no matching close
/// anywhere after it is not a fence at all: the line (and everything after,
/// since there is nowhere else for it to end) renders as plain text instead
/// of silently swallowing the rest of the message.
List<MessageBlock> splitMessageBlocks(String content) {
  final lines = content.split('\n');
  final blocks = <MessageBlock>[];
  final textLines = <String>[];

  void flushText() {
    if (textLines.isNotEmpty) {
      blocks.add(TextBlock(textLines.join('\n')));
      textLines.clear();
    }
  }

  var i = 0;
  while (i < lines.length) {
    final open = _fenceOpen.firstMatch(lines[i]);
    if (open != null) {
      var close = -1;
      for (var j = i + 1; j < lines.length; j++) {
        if (_fenceClose.hasMatch(lines[j])) {
          close = j;
          break;
        }
      }
      if (close != -1) {
        flushText();
        final lang = open.group(1)!.trim();
        blocks.add(
          CodeBlock(
            lang.isEmpty ? null : lang,
            lines.sublist(i + 1, close).join('\n'),
          ),
        );
        i = close + 1;
        continue;
      }
    }
    textLines.add(lines[i]);
    i++;
  }
  flushText();
  return blocks;
}
