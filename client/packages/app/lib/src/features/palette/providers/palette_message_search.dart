// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette's message hits for the current query, page by page, and how
/// the last request ended. A later query retires any request still in
/// flight, so a slow answer never lands under the wrong query.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:slimm_api/api.dart' as api;

import '../../messages/providers/message_search.dart';
import '../../messages/providers/message_search_query.dart';

class PaletteMessageSearch extends ChangeNotifier {
  PaletteMessageSearch(this._read);

  final ProviderReader _read;
  ParsedSearchQuery? _query;
  int _limit = 0;
  String? _cursor;
  Timer? _debounce;
  Completer<void>? _debounced;
  Future<void>? _firstPage;
  int _generation = 0;
  bool _disposed = false;

  List<api.Message> results = const [];

  /// A first page or a further one is on its way.
  bool loading = false;

  /// The last request was a 403: retrying it will not help.
  bool forbidden = false;

  /// The last request failed some other way.
  bool failed = false;

  /// The last page came back full, so there may be more.
  bool more = false;

  /// Whether [results] answer the latest query, rather than one typed before it.
  bool current = true;

  /// Drops every hit and any request in flight.
  void clear() {
    _debounce?.cancel();
    _generation++;
    _query = null;
    current = true;
    _set(results: const [], loading: false, more: false);
  }

  /// Searches [query] afresh, [limit] hits to a page, once [debounce] has
  /// passed with no newer query, so fast typing sends one request, not one a key.
  Future<void> run(
    ParsedSearchQuery query, {
    required int limit,
    Duration debounce = Duration.zero,
  }) {
    _query = query;
    _limit = limit;
    current = false;
    _debounce?.cancel();
    if (debounce == Duration.zero) {
      return _firstPage = _page(query, after: null);
    }
    _generation++;
    loading = true;
    _notify();
    final done = _debounced = Completer<void>();
    _debounce = Timer(debounce, () => done.complete(_send(query)));
    return done.future;
  }

  Future<void> _send(ParsedSearchQuery query) =>
      _firstPage = _page(query, after: null);

  /// Sends a query still waiting out its pause at once, and completes when the
  /// latest query's first page has landed, for Enter to act on its hits.
  Future<void> flush() {
    final query = _query;
    if (query == null || current) return Future.value();
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      _debounced?.complete(_send(query));
    }
    return _firstPage ?? Future.value();
  }

  /// The next page after the hits already shown.
  Future<void> loadMore() async {
    final query = _query;
    if (query == null || loading || !more) return;
    await _page(query, after: _cursor);
  }

  /// Runs the last query again, from its first page.
  Future<void> retry() async {
    final query = _query;
    if (query != null) await (_firstPage = _page(query, after: null));
  }

  Future<void> _page(ParsedSearchQuery query, {required String? after}) async {
    final generation = ++_generation;
    loading = true;
    _notify();
    final result = await searchMessages(
      _read,
      query,
      limit: _limit,
      beforeId: after,
    );
    if (_disposed || generation != _generation) return;
    if (after == null) current = true;
    final earlier = after == null ? const <api.Message>[] : results;
    switch (result) {
      case MessageSearchHits(:final messages, :final fetched, :final lastId):
        _cursor = lastId;
        _set(
          results: [...earlier, ...messages],
          loading: false,
          more: fetched >= _limit,
        );
      case MessageSearchForbidden():
        _set(results: const [], loading: false, more: false, forbidden: true);
      case MessageSearchFailed():
        _set(results: earlier, loading: false, more: false, failed: true);
    }
  }

  void _set({
    required List<api.Message> results,
    required bool loading,
    required bool more,
    bool forbidden = false,
    bool failed = false,
  }) {
    this.results = results;
    this.loading = loading;
    this.more = more;
    this.forbidden = forbidden;
    this.failed = failed;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _disposed = true;
    super.dispose();
  }
}
