// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a message mentions a given username, for anything that needs the
/// answer as a plain bool rather than as rendered chips - today, deciding a
/// `mention` notification chime apart from an ordinary `group_message` one.
/// Split out of `message_inline.dart` to keep that file under this repo's
/// review budget.
library;

import 'message_fences.dart';
import 'message_inline.dart';

/// Whether [content] mentions [username], case-insensitively. A fenced block
/// is code, so only the text between fences is read; inline code is skipped by
/// [parseInline] itself. Walked through the real [parseInline] tree rather
/// than re-run as a bare regex, so a mention nested inside bold, italic, strikethrough or a spoiler is
/// still found the same way the transcript itself would render it.
bool messageMentionsUsername(String content, String username) {
  if (username.isEmpty) return false;
  return _mentions(content, username: username);
}

bool _mentions(String content, {required String username}) {
  final target = username.toLowerCase();

  bool hit(InlineNode node) => switch (node) {
    InlineMention(:final raw) =>
      target.isNotEmpty && raw.substring(1).toLowerCase() == target,
    InlineBold(:final children) ||
    InlineItalic(:final children) ||
    InlineStrikethrough(:final children) ||
    InlineSpoiler(:final children) => children.any(hit),
    InlineText() ||
    InlineCode() ||
    InlineEmoji() ||
    InlineRoleMention() ||
    InlineLink() ||
    InlineMessageLink() ||
    InlineChannelMention() => false,
  };

  return splitMessageBlocks(
    content,
  ).whereType<TextBlock>().any((block) => parseInline(block.text).any(hit));
}
