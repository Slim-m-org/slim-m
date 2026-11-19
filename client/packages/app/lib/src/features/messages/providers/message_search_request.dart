// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A parsed query as the search routes take it: one value per parameter,
/// the dates folded into the tightest `after_date`/`before_date` window.
library;

import 'message_search_query.dart';

class MessageSearchRequest {
  const MessageSearchRequest({
    this.q,
    this.channelId,
    this.inChannel,
    this.from,
    this.mentions,
    this.has,
    this.pinned,
    this.afterDate,
    this.beforeDate,
  });

  final String? q;

  /// An `in:` picked from a list: searched through its own channel's route.
  final String? channelId;

  /// An `in:` typed by name, which the server resolves.
  final String? inChannel;
  final String? from;
  final String? mentions;

  /// Every `has:` kind, comma-joined.
  final String? has;
  final bool? pinned;

  /// Inclusive, `YYYY-MM-DD`.
  final String? afterDate;

  /// Exclusive, `YYYY-MM-DD`.
  final String? beforeDate;

  /// Whether the server would refuse it for naming nothing to search by.
  bool get isEmpty =>
      q == null &&
      channelId == null &&
      inChannel == null &&
      from == null &&
      mentions == null &&
      has == null &&
      pinned == null &&
      afterDate == null &&
      beforeDate == null;
}

MessageSearchRequest messageSearchRequest(ParsedSearchQuery parsed) {
  final scope = parsed.last(SearchKey.inChannel);
  final kinds = {for (final f in parsed.all(SearchKey.has)) f.value};
  final window = _window(parsed);
  return MessageSearchRequest(
    q: parsed.text.isEmpty ? null : parsed.text,
    channelId: scope?.channelId,
    inChannel: scope?.channelId == null ? scope?.value : null,
    from: parsed.last(SearchKey.from)?.value,
    mentions: parsed.last(SearchKey.mentions)?.value,
    has: kinds.isEmpty ? null : kinds.join(','),
    pinned: switch (parsed.last(SearchKey.pinned)?.value) {
      null => null,
      final value => value == 'true',
    },
    afterDate: window.after == null ? null : searchDayText(window.after!),
    beforeDate: window.before == null ? null : searchDayText(window.before!),
  );
}

/// The latest start and the earliest end every date filter allows.
({DateTime? after, DateTime? before}) _window(ParsedSearchQuery parsed) {
  DateTime? after;
  DateTime? before;
  void bound({DateTime? from, DateTime? until}) {
    if (from != null && (after == null || from.isAfter(after!))) after = from;
    if (until != null && (before == null || until.isBefore(before!))) {
      before = until;
    }
  }

  for (final filter in parsed.filters) {
    final value = filter.value;
    switch (filter.key) {
      case SearchKey.after:
        bound(from: searchDay(value));
      case SearchKey.before:
        bound(until: searchDay(value));
      case SearchKey.during:
        final period = searchPeriod(value);
        bound(from: period?.from, until: period?.until);
      case SearchKey.between:
        final span = searchSpan(value);
        bound(from: span?.from, until: span?.until);
      default:
        break;
    }
  }
  return (after: after, before: before);
}

/// [day] as `YYYY-MM-DD`.
String searchDayText(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';
