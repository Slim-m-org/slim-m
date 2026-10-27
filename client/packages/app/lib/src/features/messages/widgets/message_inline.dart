// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A hand-rolled recursive-descent parser for inline Discord-flavoured
/// markdown: `**bold**`, `*italic*`/`_italic_`, `~~strikethrough~~` and
/// `||spoiler||`, nesting inside one another, plus the three leaf tokens
/// `message_text.dart` already recognised: inline code, `@mention` and
/// `:shortcode:`.
///
/// Deliberately not the `markdown` or `flutter_markdown` package: both render
/// a whole document with their own theming and produce plain spans, never
/// the `WidgetSpan` mentions and custom-emoji images this client needs, so
/// hand-rolling the one grammar actually used is less code than fighting a
/// general-purpose renderer into emitting them. A single flat regex (the
/// shape `message_text.dart` used before this file existed) cannot express
/// nesting at all, which is why this is a parser rather than a bigger regex.
library;

import 'message_inline_nodes.dart';

export 'message_inline_nodes.dart';

/// A mention's charset, greedy: the first character must be a word
/// character, and `.`/`-` are accepted as interior separators alongside the
/// rest, matching what `validate_username` (`crates/slimm-server/src/http/
/// auth.rs`) allows a real account to be named. The greedy match is trimmed
/// of trailing `.`/`-` by [_trimMentionEnd] below, since a username cannot
/// be told apart from sentence punctuation by charset alone.
final RegExp _mentionPattern = RegExp(r'@[A-Za-z0-9_][A-Za-z0-9_.-]*');

/// A bare URL: http or https only, up to the next whitespace. Trailing
/// sentence punctuation is trimmed afterward by [_trimUrlEnd] rather than
/// excluded here, since a `)` or `.` can be genuinely part of a URL.
final RegExp _urlPattern = RegExp(r'https?://[^\s]+');
final RegExp _bracketedUrlPattern = RegExp(r'<(https?://[^\s<>]+)>');

/// A message link, matched narrowly: this exact scheme and host, nothing else.
///
/// Narrow on purpose. Widening it to any `slimm://` would make every app-scheme
/// link in a message body tappable, and the only one this app has any business
/// acting on from a message is a link to a message. An invite arriving in a
/// message body is deliberately not tappable - `deep_links.dart` explains why a
/// pasted invite must still go through the join flow's own checks.
final RegExp _messageLinkPattern = RegExp(r'slimm://message\?[^\s]+');
final RegExp _channelMentionPattern = RegExp(r'<#([0-9A-Fa-f-]{32,36})>');
final RegExp _emojiPattern = RegExp(r':[A-Za-z0-9_]{1,32}:');
final RegExp _digitsOnly = RegExp(r'^[0-9]+$');
final RegExp _wordChar = RegExp(r'[A-Za-z0-9_]');

/// The characters a backslash can escape: the delimiters this grammar owns
/// plus the block markers, so `\# x` and `\> x` read as text too.
const String _escapable = r'\*_~|`@:[]#>-';

/// Whether [s] holds a backslash at [i] that escapes the character after it.
bool _isEscapeAt(String s, int i) =>
    s[i] == r'\' && i + 1 < s.length && _escapable.contains(s[i + 1]);

bool _isWordAt(String s, int i) =>
    i >= 0 && i < s.length && _wordChar.hasMatch(s[i]);

/// Whitespace, or off either end of the string: both count as a boundary a
/// delimiter cannot open or close against.
bool _isBoundary(String s, int i) =>
    i < 0 || i >= s.length || s[i] == ' ' || s[i] == '\t' || s[i] == '\n';

bool _isDigit(String s, int i) {
  final unit = s.codeUnitAt(i);
  return unit >= 0x30 && unit <= 0x39;
}

/// A name made only of digits reads as part of a clock time when a digit sits
/// against either colon (`10:30:45`), the same rule `message_text.dart` used
/// to apply directly; moved here since this is now where `:shortcode:` is
/// first recognised.
bool _readsAsDigitRun(String s, int start, int end) {
  final inner = s.substring(start + 1, end - 1);
  if (!_digitsOnly.hasMatch(inner)) return false;
  final before = start - 1;
  return (before >= 0 && _isDigit(s, before)) ||
      (end < s.length && _isDigit(s, end));
}

/// Trims trailing `.`/`-` off a greedy `[start, end)` mention match, so
/// `@nick.` at the end of a sentence keeps the full stop out of the name.
/// `start` is the `@`, so `start + 2` is the first index that may never be
/// stripped: the character right after `@` is always a word character by
/// [_mentionPattern]'s own anchor, and this loop never removes it. The cost:
/// a username genuinely ending in `.` or `-` can never be mentioned, since
/// its trailing character reads as punctuation instead. Kept in sync with
/// `mentioned_usernames` in `crates/slimm-server/src/push/recipients.rs`,
/// which strips the same way over the same charset.
int _trimMentionEnd(String s, int start, int end) {
  while (end > start + 2 && (s[end - 1] == '.' || s[end - 1] == '-')) {
    end--;
  }
  return end;
}

/// Trims trailing characters off a greedy `[start, end)` URL match that read
/// as sentence punctuation rather than part of the address: `.`, `,`, `;`,
/// `:`, `!`, `?`, and a `)`/`]`/`}` that has no matching opener inside the
/// URL (so `(en.wikipedia.org/wiki/Dart_(language))` keeps its balanced
/// parens, but `(see https://x.com)` drops the closer). Never trims below
/// `start + 1`, so a URL is never emptied to nothing.
int _trimUrlEnd(String s, int start, int end) {
  const trailing = '.,;:!?';
  while (end > start + 1) {
    final c = s[end - 1];
    if (trailing.contains(c)) {
      end--;
      continue;
    }
    if (c == ')' || c == ']' || c == '}') {
      final open = _openerFor(c);
      final opens = _countChar(s, start, end - 1, open);
      final closes = _countChar(s, start, end - 1, c);
      if (closes >= opens) {
        end--;
        continue;
      }
    }
    break;
  }
  return end;
}

String _openerFor(String closer) => switch (closer) {
  ')' => '(',
  ']' => '[',
  _ => '{',
};

int _countChar(String s, int start, int end, String ch) {
  var n = 0;
  for (var k = start; k < end; k++) {
    if (s[k] == ch) n++;
  }
  return n;
}

/// The index just past the closing `]` of an `@[Name]` role mention opening
/// at [start] (where `s[start] == '@'` and `s[start + 1] == '['`), or -1
/// when there is no `]` before a newline or the end of the string - matched
/// the identical way `mentioned_role_names` in `crates/slimm-server/src/
/// push/recipients.rs` scans the same grammar.
int _roleMentionEnd(String s, int start) {
  final from = start + 2;
  for (var j = from; j < s.length; j++) {
    if (s[j] == '\n') return -1;
    if (s[j] == ']') return j + 1;
  }
  return -1;
}

/// The index just past a backtick-delimited code span starting at [start]
/// (where `s[start] == '`'`), or -1 when there is no closing backtick before
/// a newline: inline code never crosses one, since it is a short run.
int _codeSpanEnd(String s, int start) {
  var j = start + 1;
  while (j < s.length && s[j] != '`' && s[j] != '\n') {
    j++;
  }
  return (j < s.length && s[j] == '`' && j > start + 1) ? j : -1;
}

/// Scans forward from [from] for the literal [closer], skipping over any
/// inline code span whole so a fence character inside code is never mistaken
/// for a markdown delimiter.
int _findCloser(String s, int from, String closer) {
  var j = from;
  while (j <= s.length - closer.length) {
    if (_isEscapeAt(s, j)) {
      j += 2;
      continue;
    }
    if (s[j] == '`') {
      final end = _codeSpanEnd(s, j);
      j = end == -1 ? j + 1 : end + 1;
      continue;
    }
    if (s.substring(j, j + closer.length) == closer) return j;
    j++;
  }
  return -1;
}

/// A lone `*` closer: not adjacent to another `*` on either side (which
/// would make it part of a `**` pair instead), and not preceded by
/// whitespace, which is what keeps `2 * 3` from closing on its own space.
int _findItalicStarCloser(String s, int from) {
  var j = from;
  while (j < s.length) {
    if (_isEscapeAt(s, j)) {
      j += 2;
      continue;
    }
    if (s[j] == '`') {
      final end = _codeSpanEnd(s, j);
      j = end == -1 ? j + 1 : end + 1;
      continue;
    }
    if (s[j] == '*' &&
        (j == 0 || s[j - 1] != '*') &&
        (j + 1 >= s.length || s[j + 1] != '*') &&
        !_isBoundary(s, j - 1)) {
      return j;
    }
    j++;
  }
  return -1;
}

/// A `_` closer: not preceded by whitespace and not followed by a word
/// character, which is what keeps `snake_case_name` from closing mid-word.
int _findItalicUnderscoreCloser(String s, int from) {
  var j = from;
  while (j < s.length) {
    if (_isEscapeAt(s, j)) {
      j += 2;
      continue;
    }
    if (s[j] == '`') {
      final end = _codeSpanEnd(s, j);
      j = end == -1 ? j + 1 : end + 1;
      continue;
    }
    if (s[j] == '_' && !_isBoundary(s, j - 1) && !_isWordAt(s, j + 1)) {
      return j;
    }
    j++;
  }
  return -1;
}

/// Parses [content] into a tree of [InlineNode]s.
///
/// A delimiter pair nests by recursing over the substring between an opener
/// and its matched closer, which is what lets `**bold with *italic* inside**`
/// parse as a bold run containing an italic run: something no flat regex can
/// express. An opener with no matching closer anywhere after it is not a
/// delimiter at all and is left as the literal character it was typed as.
List<InlineNode> parseInline(String content) {
  final nodes = <InlineNode>[];
  final buffer = StringBuffer();
  var i = 0;

  void flush() {
    if (buffer.isNotEmpty) {
      nodes.add(InlineText(buffer.toString()));
      buffer.clear();
    }
  }

  while (i < content.length) {
    if (_isEscapeAt(content, i)) {
      buffer.write(content[i + 1]);
      i += 2;
      continue;
    }
    final token = _tokenAt(content, i);
    if (token == null) {
      buffer.write(content[i]);
      i++;
      continue;
    }
    flush();
    nodes.add(token.node);
    i = token.end;
  }

  flush();
  return nodes;
}

typedef _Token = ({InlineNode node, int end});

/// The inline token opening at [i], or null when [i] starts no token and is
/// literal text.
_Token? _tokenAt(String s, int i) => switch (s[i]) {
  '`' => _codeSpanToken(s, i),
  '*' => _starToken(s, i),
  '~' => _doubledToken(s, i, '~~', InlineStrikethrough.new),
  '|' => _doubledToken(s, i, '||', InlineSpoiler.new),
  '_' => _underscoreToken(s, i),
  '@' => _atToken(s, i),
  '<' => _channelToken(s, i),
  ':' => _emojiToken(s, i),
  's' => _messageLinkToken(s, i),
  'h' => _linkToken(s, i),
  _ => null,
};

bool _doubledAt(String s, int i) => i + 1 < s.length && s[i + 1] == s[i];

_Token? _codeSpanToken(String s, int i) {
  final end = _codeSpanEnd(s, i);
  if (end == -1) return null;
  return (node: InlineCode(s.substring(i + 1, end)), end: end + 1);
}

_Token? _doubledToken(
  String s,
  int i,
  String delimiter,
  InlineNode Function(List<InlineNode>) make,
) {
  if (!_doubledAt(s, i)) return null;
  final close = _findCloser(s, i + 2, delimiter);
  if (close == -1) return null;
  return (node: make(parseInline(s.substring(i + 2, close))), end: close + 2);
}

// A `**` that finds no closer stays literal, it never falls back to italic.
_Token? _starToken(String s, int i) {
  if (_doubledAt(s, i)) return _doubledToken(s, i, '**', InlineBold.new);
  if (_isBoundary(s, i + 1)) return null;
  final close = _findItalicStarCloser(s, i + 1);
  if (close == -1) return null;
  return (
    node: InlineItalic(parseInline(s.substring(i + 1, close))),
    end: close + 1,
  );
}

_Token? _underscoreToken(String s, int i) {
  if (_isWordAt(s, i - 1) || _isBoundary(s, i + 1)) return null;
  final close = _findItalicUnderscoreCloser(s, i + 1);
  if (close == -1) return null;
  return (
    node: InlineItalic(parseInline(s.substring(i + 1, close))),
    end: close + 1,
  );
}

_Token? _atToken(String s, int i) {
  final role = _roleMentionToken(s, i);
  if (role != null) return role;
  final m = _mentionPattern.matchAsPrefix(s, i);
  if (m == null) return null;
  final end = _trimMentionEnd(s, i, m.end);
  return (node: InlineMention(s.substring(i, end)), end: end);
}

_Token? _roleMentionToken(String s, int i) {
  if (i + 1 >= s.length || s[i + 1] != '[') return null;
  final end = _roleMentionEnd(s, i);
  if (end == -1) return null;
  final name = s.substring(i + 2, end - 1).trim();
  if (name.isEmpty) return null;
  return (node: InlineRoleMention(name), end: end);
}

_Token? _channelToken(String s, int i) {
  final m = _channelMentionPattern.matchAsPrefix(s, i);
  if (m == null) return _bracketedLinkToken(s, i);
  return (node: InlineChannelMention(m.group(1)!.toLowerCase()), end: m.end);
}

_Token? _bracketedLinkToken(String s, int i) {
  final m = _bracketedUrlPattern.matchAsPrefix(s, i);
  if (m == null) return null;
  return (node: InlineLink(m.group(1)!, noPreview: true), end: m.end);
}

_Token? _emojiToken(String s, int i) {
  final m = _emojiPattern.matchAsPrefix(s, i);
  if (m == null || _readsAsDigitRun(s, m.start, m.end)) return null;
  return (node: InlineEmoji(m.group(0)!), end: m.end);
}

// Same "only starts a token" rule the http match below follows.
_Token? _messageLinkToken(String s, int i) {
  if (_isWordAt(s, i - 1)) return null;
  final m = _messageLinkPattern.matchAsPrefix(s, i);
  if (m == null) return null;
  final end = _trimUrlEnd(s, i, m.end);
  return (node: InlineMessageLink(s.substring(i, end)), end: end);
}

// A URL only starts a token, never mid-word; trailing punctuation is trimmed off the greedy match.
_Token? _linkToken(String s, int i) {
  if (_isWordAt(s, i - 1)) return null;
  final m = _urlPattern.matchAsPrefix(s, i);
  if (m == null) return null;
  final end = _trimUrlEnd(s, i, m.end);
  return (node: InlineLink(s.substring(i, end)), end: end);
}

/// The `http(s)` URLs in [content], in order of first appearance and
/// deduplicated, capped at [max]. Reuses [parseInline] rather than
/// re-running [_urlPattern] directly, so a link preview sees exactly the
/// same URLs the message body itself renders as tappable links - including
/// the same trailing-punctuation trim - even one nested inside `**bold**` or
/// similar.
///
/// A URL in angle brackets, `<https://...>`, is skipped too: it is how a
/// person asks for the link with no card.
///
/// A URL inside a spoiler is deliberately skipped: an open preview card below
/// the message would show the title and image the `||spoiler||` exists to
/// hide, so a spoilered link gets no card.
List<String> extractLinkPreviewUrls(String content, {int max = 2}) {
  final urls = <String>[];
  void walk(List<InlineNode> nodes) {
    for (final node in nodes) {
      if (urls.length >= max) return;
      switch (node) {
        case InlineLink(:final url, :final noPreview):
          if (!noPreview && !urls.contains(url)) urls.add(url);
        case InlineBold(:final children):
          walk(children);
        case InlineItalic(:final children):
          walk(children);
        case InlineStrikethrough(:final children):
          walk(children);
        default:
          break;
      }
    }
  }

  walk(parseInline(content));
  return urls;
}
