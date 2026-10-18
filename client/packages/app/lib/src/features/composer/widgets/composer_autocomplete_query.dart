// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the caret is currently in the middle of typing, if anything.
///
/// Kept as one pure function over (text, caret) with no widget, controller or
/// provider anywhere near it, because every interesting case here is a string
/// case and this is the half that decides whether the feature feels right or
/// fires in your face: `12:30` must not offer emoji, `https://x` must not
/// offer commands, and an `@` inside an address must not offer members.
library;

/// Which vocabulary a trigger opens.
enum AutocompleteKind {
  /// `:` plus at least [minEmojiChars] characters.
  emoji,

  /// `@`, from the first character.
  mention,

  /// `/`, and only as the very first thing in the message.
  command,

  /// A bot's own registered prefix, and only as the very first thing in the
  /// message. Lists just the commands of the bots that registered it.
  botCommand,
}

/// Emoji needs two characters before it offers anything.
///
/// One is not enough: a bare `:` fires on every clock time and every `:)`, and
/// a single letter still matches most of the catalog, so the list would be
/// noise in front of somebody who was not asking for it.
const int minEmojiChars = 2;

/// A trigger under the caret: what kind, what has been typed after it, and the
/// span to replace when something is chosen.
class AutocompleteQuery {
  const AutocompleteQuery({
    required this.kind,
    required this.term,
    required this.start,
    required this.end,
    this.prefix = '',
  });

  final AutocompleteKind kind;

  /// What follows the trigger character, lowercased. Empty is legitimate for
  /// [AutocompleteKind.mention] and [AutocompleteKind.command].
  final String term;

  /// Offsets of the whole trigger including its leading character, so a
  /// replacement covers the `:sh` as well as what replaces it.
  final int start;
  final int end;

  /// The bot prefix a [AutocompleteKind.botCommand] query matched; empty otherwise.
  final String prefix;

  @override
  bool operator ==(Object other) =>
      other is AutocompleteQuery &&
      other.kind == kind &&
      other.prefix == prefix &&
      other.term == term &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(kind, term, start, end, prefix);

  @override
  String toString() => 'AutocompleteQuery($kind, "$term", $start..$end)';
}

/// The trigger the caret sits inside, or null.
///
/// Scans backwards from the caret to the nearest trigger character, refusing
/// as soon as anything disqualifies it. Reasons a candidate is refused, each
/// of which is a real thing people type:
///
/// - **A trigger mid-word is not a trigger.** It must start the message or
///   follow whitespace, so `12:30`, `a@b.com` and `https://host` are left
///   alone. This one rule covers most of the false positives.
/// - **Whitespace ends a term.** Emoji shortcodes and usernames have none, so
///   a space means the caret is past whatever the trigger opened.
/// - **A closing colon ends an emoji.** `:shrug:` is finished; offering
///   completions for a completed shortcode is just in the way.
/// - **`/` only counts at offset zero.** A slash command is the whole message
///   or it is not a command, which is also what keeps every path and every
///   `and/or` out of it.
///
/// [botPrefixes] are the prefixes bots registered in this channel; the message
/// starting with one, with the caret still in that first word, opens a
/// [AutocompleteKind.botCommand] query (the longest matching prefix wins).
AutocompleteQuery? autocompleteQueryAt(
  String text,
  int caret, {
  Iterable<String> botPrefixes = const [],
}) {
  if (caret < 0 || caret > text.length) return null;
  final botQuery = _botPrefixQuery(text, caret, botPrefixes);
  if (botQuery != null) return botQuery;

  for (var i = caret - 1; i >= 0; i--) {
    final ch = text[i];

    // Whitespace before any trigger means the caret is not inside one.
    if (_isSpace(ch)) return null;

    final kind = switch (ch) {
      ':' => AutocompleteKind.emoji,
      '@' => AutocompleteKind.mention,
      '/' => AutocompleteKind.command,
      _ => null,
    };
    if (kind == null) continue;
    return _queryAtTrigger(text, caret, i, kind);
  }
  return null;
}

AutocompleteQuery? _botPrefixQuery(
  String text,
  int caret,
  Iterable<String> botPrefixes,
) {
  String? matched;
  for (final prefix in botPrefixes) {
    if (!text.startsWith(prefix) || caret < prefix.length) continue;
    if (matched == null || prefix.length > matched.length) matched = prefix;
  }
  if (matched == null) return null;
  final term = text.substring(matched.length, caret);
  if (term.contains(RegExp(r'\s'))) return null;
  return AutocompleteQuery(
    kind: AutocompleteKind.botCommand,
    term: term.toLowerCase(),
    start: 0,
    end: caret,
    prefix: matched,
  );
}

bool _isSpace(String ch) => ch == ' ' || ch == '\n' || ch == '\t';

AutocompleteQuery? _queryAtTrigger(
  String text,
  int caret,
  int i,
  AutocompleteKind kind,
) {
  // A command is the whole message or nothing.
  if (kind == AutocompleteKind.command && i != 0) return null;

  // Must start the message or follow whitespace.
  if (i > 0 && !_isSpace(text[i - 1])) return null;

  final term = text.substring(i + 1, caret);
  // A closed shortcode is finished; a space means the caret is past it.
  if (term.contains(':') || term.contains(' ')) return null;

  if (kind == AutocompleteKind.emoji && term.length < minEmojiChars) {
    return null;
  }

  return AutocompleteQuery(
    kind: kind,
    term: term.toLowerCase(),
    start: i,
    end: caret,
  );
}
