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

/// Whether [content] is addressed to this account: its own `@username`, the
/// broadcast mentions `@everyone` and `@here`, or `@[Role]` for a role in
/// [roleNames]. What the server pushes for under a mentions-only preference,
/// less its check of whether the author may broadcast, which the client
/// cannot see: a message that looks like a mention in the transcript is
/// treated as one here.
bool messageMentionsMe(
  String content, {
  required String username,
  Iterable<String> roleNames = const [],
}) => _mentions(
  content,
  username: username,
  broadcast: true,
  roleNames: {for (final name in roleNames) name.toLowerCase()},
);

bool _mentions(
  String content, {
  required String username,
  bool broadcast = false,
  Set<String> roleNames = const {},
}) {
  final target = username.toLowerCase();

  bool walk(List<InlineNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        case InlineMention(:final raw):
          final name = raw.substring(1).toLowerCase();
          if (target.isNotEmpty && name == target) return true;
          if (broadcast && (name == 'everyone' || name == 'here')) return true;
        case InlineRoleMention(:final name):
          if (roleNames.contains(name.toLowerCase())) return true;
        case InlineBold(:final children):
        case InlineItalic(:final children):
        case InlineStrikethrough(:final children):
        case InlineSpoiler(:final children):
          if (walk(children)) return true;
        case InlineText():
        case InlineCode():
        case InlineEmoji():
        case InlineLink():
        case InlineMessageLink():
          break;
      }
    }
    return false;
  }

  return splitMessageBlocks(
    content,
  ).whereType<TextBlock>().any((block) => walk(parseInline(block.text)));
}
