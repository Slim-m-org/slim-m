// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The badges modules show beside members in the roster, fetched in batches.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';

/// The server's cap on ids per request.
const int moduleBadgeBatchSize = 100;

/// How long an answer stands before a row asking again refetches it.
const Duration moduleBadgeTtl = Duration(seconds: 60);

/// The clock the refetch limit reads, overridable so a test needs no waiting.
final moduleBadgesClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Badges by member id; a member asked about and found bare holds an empty
/// list, one never asked about is absent.
class ModuleBadgesController
    extends StateNotifier<Map<String, List<api.ModuleBadge>>> {
  ModuleBadgesController(this._ref) : super(const {}) {
    _sub = _ref.read(liveEventsProvider).listen((event) {
      if (event is api.MemberRemoved) _evict(event.userId);
    });
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;
  final Map<String, DateTime> _askedAt = {};
  final Set<String> _unsent = {};
  bool _flushScheduled = false;

  /// Asks for [id]'s badges unless an answer is under [moduleBadgeTtl] old.
  ///
  /// Every id asked for in one frame rides the same flush, so a roster of
  /// 150 rows costs two requests, not 150.
  void request(String id) {
    final asked = _askedAt[id];
    if (asked != null && _now().difference(asked) < moduleBadgeTtl) return;
    _askedAt[id] = _now();
    _unsent.add(id);
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(_flush);
  }

  DateTime _now() => _ref.read(moduleBadgesClockProvider)();

  void _flush() {
    _flushScheduled = false;
    final ids = _unsent.toList(growable: false);
    _unsent.clear();
    for (var i = 0; i < ids.length; i += moduleBadgeBatchSize) {
      final end = i + moduleBadgeBatchSize;
      unawaited(_fetch(ids.sublist(i, end < ids.length ? end : ids.length)));
    }
  }

  Future<void> _fetch(List<String> ids) async {
    try {
      final found = await _ref.read(apiProvider).moduleBadges(ids);
      if (!mounted) return;
      state = {
        ...state,
        for (final id in ids) id: found[id] ?? const <api.ModuleBadge>[],
      };
    } catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'load module badges', error, stack);
    }
  }

  void _evict(String id) {
    _askedAt.remove(id);
    if (state.containsKey(id)) state = {...state}..remove(id);
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

final moduleBadgesProvider =
    StateNotifierProvider<
      ModuleBadgesController,
      Map<String, List<api.ModuleBadge>>
    >((ref) => ModuleBadgesController(ref));
