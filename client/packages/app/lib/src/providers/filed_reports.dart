// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Report ids filed from this device, remembered locally so
/// `ReportStatusSection` can show a reporter their own filed reports without
/// them ever having to write an id down.
///
/// `POST /reports` already hands the new id back; the gap this closes is
/// that nothing on the client kept it anywhere, so `GET /reports/mine/{id}`
/// existed with no realistic way for a reporter to reach it. This is a pure
/// device-local convenience list, the same shape `recent_emoji.dart`
/// documents for its own shelf: capped, best-effort, and no server truth of
/// its own. Losing it (a reinstall, clearing site data) loses nothing but
/// the shortcut - the manual "check a report by id" field stays as the
/// fallback.
///
/// Keyed per account like `personal_space_visibility.dart`: the local
/// `SharedPreferences` store is one file for the whole device, not one per
/// account, so an unkeyed list would show the next signed-in account the
/// previous one's filed reports.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'providers.dart';

const _maxFiledReports = 20;

/// The `SharedPreferences` key one account's filed-report list is stored
/// under.
String filedReportsKey(String userId) => 'slimm.reports.filed.$userId';

class FiledReportsController extends StateNotifier<List<String>> {
  FiledReportsController(this._ref) : super(const []) {
    _account = _ref.read(sessionProvider).tokens?.userId;
    _sub = _ref.read(sessionProvider).changes.listen(_onSessionChanged);
    _loading = _load();
  }

  final Ref _ref;
  late final StreamSubscription<api.TokenPair?> _sub;

  /// Whose list is held; see `PersonalSpaceVisibilityController`'s own field
  /// for why this is tracked separately from a token rotation.
  String? _account;

  /// The newest stored-list read, which [record] waits on so it never builds on a list that has not loaded yet.
  Future<void> _loading = Future<void>.value();

  /// Bumped by every account change, so a load that answers after the
  /// account already changed again is dropped instead of stomping the newer
  /// account's list with the previous one's stale read.
  int _generation = 0;

  void _onSessionChanged(api.TokenPair? tokens) {
    final userId = tokens?.userId;
    if (userId == _account) return;
    _account = userId;
    _generation++;
    state = const [];
    if (userId != null) _loading = _load();
  }

  Future<void> _load() async {
    final generation = _generation;
    final userId = _account;
    if (userId == null) return;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      if (!mounted || generation != _generation) return;
      state = prefs.getStringList(filedReportsKey(userId)) ?? const [];
    } catch (_) {
      // Falls back to an empty list; the manual id field still works.
    }
  }

  /// Remembers [reportId] at the front of the list, best-effort.
  ///
  /// Bumps [_generation] first, the same guard [_onSessionChanged] uses: a
  /// [_load] already in flight from construction can otherwise answer after
  /// this sets [state] and clobber it back to whatever was last on disk.
  ///
  /// The list to persist is captured into [updated] before the only await
  /// here, and that local - not [state] - is what gets written, with
  /// [generation] re-checked after the await before writing at all. [state]
  /// itself can change out from under this call while it is suspended on
  /// [preferencesProvider]: a sign-out lands, [_onSessionChanged] bumps
  /// [_generation] and resets [state] to empty, and this call resumes still
  /// holding [userId] from the account that just signed out. Reading [state]
  /// at that point would persist an empty list under the *previous*
  /// account's key - wiping its real list - so the generation check skips
  /// the write entirely rather than persisting anything for an account this
  /// call no longer belongs to.
  Future<void> record(String reportId) async {
    await _loading;
    if (!mounted) return;
    final userId = _account;
    if (userId == null) return;
    final generation = ++_generation;
    final updated = [
      reportId,
      ...state.where((id) => id != reportId),
    ].take(_maxFiledReports).toList();
    state = updated;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      if (!mounted || generation != _generation) return;
      await prefs.setStringList(filedReportsKey(userId), updated);
    } catch (_) {
      // Best-effort: the report was still filed even if this did not persist.
    }
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// Deliberately not `autoDispose`: `ReportStatusSection` reads this whenever
/// its pane is opened, and `fileReport` (elsewhere in the widget tree) writes
/// to it, so it needs to outlive either one's own widget lifetime.
final filedReportsProvider =
    StateNotifierProvider<FiledReportsController, List<String>>(
      (ref) => FiledReportsController(ref),
    );
