// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin audit log, one page at a time: `GET /space/audit-log`, newest
/// first, paged backward with `before` set to the oldest id held.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// Under the server's clamp, and enough that a small space rarely needs two.
const int adminAuditPageSize = 50;

class AdminAuditLogState {
  const AdminAuditLogState({
    this.items = const [],
    this.loading = true,
    this.error,
    this.more = false,
  });

  final List<api.AdminChange> items;
  final bool loading;

  /// Kept beside [items], so a failed "load more" keeps the pages on screen.
  final String? error;

  /// Whether the last page came back full, the only sign that more follows.
  final bool more;
}

class AdminAuditLogController extends StateNotifier<AdminAuditLogState> {
  AdminAuditLogController(this._ref) : super(const AdminAuditLogState()) {
    unawaited(refresh());
  }

  final Ref _ref;

  /// A response that lands after a newer load started is dropped.
  int _generation = 0;

  Future<void> refresh() async {
    state = AdminAuditLogState(items: state.items, more: state.more);
    await _load(before: null, onto: const []);
  }

  Future<void> loadMore() async {
    if (state.loading || !state.more || state.items.isEmpty) return;
    state = AdminAuditLogState(items: state.items, more: true);
    await _load(before: state.items.last.id, onto: state.items);
  }

  Future<void> _load({
    required int? before,
    required List<api.AdminChange> onto,
  }) async {
    final generation = ++_generation;
    final held = state.items;
    final more = state.more;
    try {
      final page = await _ref
          .read(apiProvider)
          .listAdminChanges(before: before, limit: adminAuditPageSize);
      if (!mounted || generation != _generation) return;
      state = AdminAuditLogState(
        items: [...onto, ...page],
        loading: false,
        more: page.length >= adminAuditPageSize,
      );
    } on Object catch (e) {
      if (!mounted || generation != _generation) return;
      state = AdminAuditLogState(
        items: before == null ? held : onto,
        loading: false,
        error: e is api.ApiException ? e.message : 'Could not read the log.',
        more: more,
      );
    }
  }
}

final adminAuditLogControllerProvider =
    StateNotifierProvider.autoDispose<
      AdminAuditLogController,
      AdminAuditLogState
    >((ref) => AdminAuditLogController(ref));
