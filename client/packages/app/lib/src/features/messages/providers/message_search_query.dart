// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message search grammar (docs/search.md): `key:value` filters and free
/// text, where a quoted phrase stays one word. A filter word whose value does
/// not fit its key (`has:sticker`, `before:soon`) is left as free text.
library;

/// A filter's key, spelled [word] in a query.
enum SearchKey {
  from('from'),
  mentions('mentions'),
  inChannel('in'),
  has('has'),
  pinned('pinned'),
  before('before'),
  after('after'),
  during('during'),
  between('between');

  const SearchKey(this.word);

  final String word;

  /// The key spelled [word]; `type:` is read as `has:`, the word other apps use.
  static SearchKey? named(String word) => word == 'type'
      ? SearchKey.has
      : SearchKey.values.where((k) => k.word == word).firstOrNull;
}

/// What `has:` accepts, in the order suggestions list them.
const searchHasKinds = [
  'image',
  'video',
  'file',
  'link',
  'voice',
  'poll',
  'embed',
  'attachment',
];

/// One filter. [value] is canonical: a username or channel name without its
/// `@` or `#`, a `has:` kind, `true`/`false`, or a date as typed.
class SearchFilter {
  const SearchFilter(this.key, this.value, {this.label, this.channelId});

  final SearchKey key;
  final String value;

  /// What a chip shows in place of [value], such as a display name.
  final String? label;

  /// For `in:`, the channel picked from a list: searched by id, so a DM, a
  /// thread or one of two same-named channels is exactly that one.
  final String? channelId;

  /// The filter as it would be typed.
  String get typed {
    final shown = value.contains(' ') ? '"$value"' : value;
    return '${key.word}:$shown';
  }

  @override
  bool operator ==(Object other) =>
      other is SearchFilter &&
      other.key == key &&
      other.value == value &&
      other.channelId == channelId;

  @override
  int get hashCode => Object.hash(key, value, channelId);

  @override
  String toString() => typed;
}

/// A query split into its filters and the free text left over.
class ParsedSearchQuery {
  const ParsedSearchQuery({this.text = '', this.filters = const []});

  /// The words that are not filters, single-spaced, quoted phrases kept quoted.
  final String text;
  final List<SearchFilter> filters;

  bool get isEmpty => text.isEmpty && filters.isEmpty;

  /// The last filter under [key], for the keys that take one value.
  SearchFilter? last(SearchKey key) =>
      filters.where((f) => f.key == key).lastOrNull;

  /// Every filter under [key], for `has:` and the dates, which add up.
  Iterable<SearchFilter> all(SearchKey key) =>
      filters.where((f) => f.key == key);
}

/// Splits [raw] into [ParsedSearchQuery.filters] and free text; [filters]
/// already committed (the palette's chips) come first.
ParsedSearchQuery parseSearchQuery(
  String raw, {
  List<SearchFilter> filters = const [],
}) {
  final found = [...filters];
  final words = <String>[];
  for (final word in searchWords(raw)) {
    final filter = searchFilterFrom(word);
    if (filter == null) {
      words.add(word);
    } else {
      found.add(filter);
    }
  }
  return ParsedSearchQuery(text: words.join(' '), filters: found);
}

/// [raw]'s words: whitespace splits them except inside double quotes, so
/// `"exact phrase"` and `in:"two words"` are one word each.
List<String> searchWords(String raw) => [
  for (final span in searchWordSpans(raw)) raw.substring(span.start, span.end),
];

/// Where each of [searchWords] sits in [raw], as UTF-16 offsets.
List<({int start, int end})> searchWordSpans(String raw) {
  final spans = <({int start, int end})>[];
  int? start;
  var quoted = false;
  for (var i = 0; i < raw.length; i++) {
    final char = raw[i];
    if (char == '"') quoted = !quoted;
    final space = !quoted && char.trim().isEmpty;
    if (space && start != null) {
      spans.add((start: start, end: i));
      start = null;
    } else if (!space) {
      start ??= i;
    }
  }
  if (start != null) spans.add((start: start, end: raw.length));
  return spans;
}

/// The filter [word] spells, or null when it is free text.
SearchFilter? searchFilterFrom(String word) {
  final colon = word.indexOf(':');
  if (colon <= 0) return null;
  final key = SearchKey.named(word.substring(0, colon).toLowerCase());
  if (key == null) return null;
  final value = _unquoted(word.substring(colon + 1));
  final canonical = canonicalSearchValue(key, value);
  return canonical == null ? null : SearchFilter(key, canonical);
}

String _unquoted(String value) =>
    value.length >= 2 && value.startsWith('"') && value.endsWith('"')
    ? value.substring(1, value.length - 1)
    : value;

/// [value] as [key] stores it, or null when [key] cannot take it.
String? canonicalSearchValue(SearchKey key, String value) {
  final trimmed = value.trim();
  final canonical = switch (key) {
    SearchKey.from || SearchKey.mentions => _strip(trimmed, '@'),
    SearchKey.inChannel => _strip(trimmed, '#'),
    SearchKey.has =>
      searchHasKinds.contains(trimmed.toLowerCase())
          ? trimmed.toLowerCase()
          : null,
    SearchKey.pinned => switch (trimmed.toLowerCase()) {
      'true' || 'yes' => 'true',
      'false' || 'no' => 'false',
      _ => null,
    },
    SearchKey.before ||
    SearchKey.after => searchDay(trimmed) == null ? null : trimmed,
    SearchKey.during => searchPeriod(trimmed) == null ? null : trimmed,
    SearchKey.between => searchSpan(trimmed) == null ? null : trimmed,
  };
  return canonical == null || canonical.isEmpty ? null : canonical;
}

String _strip(String value, String sigil) =>
    value.startsWith(sigil) ? value.substring(1) : value;

/// A `YYYY-MM-DD` that names a real calendar day, as UTC midnight.
DateTime? searchDay(String text) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
  if (match == null) return null;
  final [year, month, day] = [
    for (var i = 1; i <= 3; i++) int.parse(match.group(i)!),
  ];
  final date = DateTime.utc(year, month, day);
  final real = date.year == year && date.month == month && date.day == day;
  return real ? date : null;
}

/// A whole day, month (`YYYY-MM`) or year (`YYYY`): its first day, and the first day after it.
({DateTime from, DateTime until})? searchPeriod(String text) {
  if (searchDay(text) case final day?) {
    return (from: day, until: DateTime.utc(day.year, day.month, day.day + 1));
  }
  final month = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(text);
  if (month != null) {
    final year = int.parse(month.group(1)!);
    final number = int.parse(month.group(2)!);
    if (number < 1 || number > 12) return null;
    return (
      from: DateTime.utc(year, number),
      until: DateTime.utc(year, number + 1),
    );
  }
  if (RegExp(r'^\d{4}$').hasMatch(text)) {
    final year = int.parse(text);
    return (from: DateTime.utc(year), until: DateTime.utc(year + 1));
  }
  return null;
}

/// `A..B` between two days, both included: A, and the day after B.
({DateTime from, DateTime until})? searchSpan(String text) {
  final ends = text.split('..');
  if (ends.length != 2) return null;
  final first = searchDay(ends[0]);
  final last = searchDay(ends[1]);
  if (first == null || last == null || last.isBefore(first)) return null;
  return (
    from: first,
    until: DateTime.utc(last.year, last.month, last.day + 1),
  );
}
