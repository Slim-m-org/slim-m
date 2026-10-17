// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Parses the Slack-style operators `http::search` accepts
/// (`from:`/`in:`/`has:`/`before:`/`after:`) out of a raw search-bar string,
/// leaving whatever free text remains.
///
/// This never validates an operator's own value - not a username's charset,
/// not a channel name, not a calendar date, not `has:`'s vocabulary. The
/// server is the one place any of those are checked (`http::search`'s
/// `validate_query`/`parse_date_start`/`parse_has`), so a value this parser
/// extracted verbatim and forwarded is either accepted or comes back as the
/// same 400 a hand-typed malformed request would; duplicating that
/// validation here would only give the two a chance to disagree.
library;

/// One operator token's value can be `""` (`in:` with nothing after the
/// colon), and that is never treated as the operator firing - an empty
/// value is indistinguishable from the operator not being there at all, so
/// `in:` alone stays in the free text.
class ParsedSearchQuery {
  const ParsedSearchQuery({
    this.text = '',
    this.from,
    this.inChannel,
    this.has,
    this.afterDate,
    this.beforeDate,
  });

  /// Whatever is left once every recognised operator token is stripped,
  /// joined back with single spaces and trimmed. Empty when the query is
  /// made entirely of operators - a valid, useful search on its own.
  final String text;

  /// `from:username`. The last one wins if given more than once.
  final String? from;

  /// `in:channel-name`. The last one wins if given more than once. A
  /// channel name containing whitespace cannot be named this way, since a
  /// token ends at the next space - the same limit `http::search`'s own doc
  /// comment states server-side.
  final String? inChannel;

  /// Every `has:` token's value, comma-joined in the order given (matching
  /// `has=attachment,link`'s wire shape) - never split or validated here,
  /// see this file's own doc comment.
  final String? has;

  /// `after:YYYY-MM-DD` as typed, forwarded verbatim.
  final String? afterDate;

  /// `before:YYYY-MM-DD` as typed, forwarded verbatim.
  final String? beforeDate;

  /// True when nothing at all was given - no free text and no operator -
  /// the one case `http::search` refuses with a 400 rather than running.
  bool get isEmpty =>
      text.isEmpty &&
      from == null &&
      inChannel == null &&
      has == null &&
      afterDate == null &&
      beforeDate == null;
}

const _fromPrefix = 'from:';
const _inPrefix = 'in:';
const _hasPrefix = 'has:';
const _afterPrefix = 'after:';
const _beforePrefix = 'before:';

/// Splits [raw] on whitespace and classifies each token: a recognised
/// operator prefix with a non-empty value after it is consumed, anything
/// else - including a bare `word:` this list does not name, and an operator
/// prefix with nothing after the colon - passes through into [text]
/// untouched.
ParsedSearchQuery parseSearchQuery(String raw) {
  String? from;
  String? inChannel;
  final hasValues = <String>[];
  String? afterDate;
  String? beforeDate;
  final remaining = <String>[];

  for (final token in raw.trim().split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    if (token.startsWith(_fromPrefix) && token.length > _fromPrefix.length) {
      from = token.substring(_fromPrefix.length);
    } else if (token.startsWith(_inPrefix) && token.length > _inPrefix.length) {
      inChannel = token.substring(_inPrefix.length);
    } else if (token.startsWith(_hasPrefix) &&
        token.length > _hasPrefix.length) {
      hasValues.add(token.substring(_hasPrefix.length));
    } else if (token.startsWith(_afterPrefix) &&
        token.length > _afterPrefix.length) {
      afterDate = token.substring(_afterPrefix.length);
    } else if (token.startsWith(_beforePrefix) &&
        token.length > _beforePrefix.length) {
      beforeDate = token.substring(_beforePrefix.length);
    } else {
      remaining.add(token);
    }
  }

  return ParsedSearchQuery(
    text: remaining.join(' '),
    from: from,
    inChannel: inChannel,
    has: hasValues.isEmpty ? null : hasValues.join(','),
    afterDate: afterDate,
    beforeDate: beforeDate,
  );
}
