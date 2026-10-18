// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The moderation queue, one page at a time.
///
/// `GET /reports` is bounded now: it used to answer with every open report in
/// the deployment and re-check visibility channel by channel, at several
/// indexed queries each, so one request's cost was set by how many reports
/// members had filed. The queue is a work list that can outgrow a screen either
/// way, so the client pages rather than the server answering with all of it.
///
/// Channels the caller cannot moderate are excluded server-side *before* the
/// limit, which is what lets "more to load" simply be "the page came back
/// full". An earlier pass filtered after the limit, and then a short page meant
/// either "some of that window was restricted" or "the queue ended" with
/// nothing in the response telling them apart - so a moderator denied
/// MANAGE_MESSAGES in one busy channel stopped paging early, and a wholly
/// restricted first window read as an empty queue.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// How many reports to ask for at a time. Under the server's own 200 ceiling,
/// and enough that a small deployment never sees a second page.
const int reportsPageSize = 50;

class ReportsState {
  const ReportsState({
    this.reports = const [],
    this.loading = true,
    this.error,
    this.more = false,
  });

  final List<api.Report> reports;
  final bool loading;

  /// The last failure, kept beside [reports] rather than instead of them: a
  /// failed "load more" must not throw away the pages already on screen.
  final String? error;

  /// Whether the last page came back full, which is the only thing that says
  /// more may follow. Preserved across a failure, or a single network blip
  /// would read as the end of the queue.
  final bool more;
}

class ReportsController extends StateNotifier<ReportsState> {
  ReportsController(this._ref) : super(const ReportsState()) {
    refresh();
  }

  final Ref _ref;

  /// Bumped by every call that starts a load, so a response that arrives after
  /// a newer one was started is dropped instead of overwriting it.
  int _generation = 0;

  /// Starts the queue again from the top.
  Future<void> refresh() async {
    state = const ReportsState();
    await _load(after: null, onto: const []);
  }

  /// Asks for the page after the last report already held.
  Future<void> loadMore() async {
    if (state.loading || !state.more || state.reports.isEmpty) return;
    state = ReportsState(reports: state.reports, loading: true, more: true);
    final last = state.reports.last;
    await _load(after: last, onto: state.reports);
  }

  Future<void> _load({
    required api.Report? after,
    required List<api.Report> onto,
  }) async {
    final generation = ++_generation;
    final more = state.more;
    try {
      final page = await _ref
          .read(apiProvider)
          .listOpenReports(
            after: after?.createdAt,
            afterId: after?.id,
            limit: reportsPageSize,
          );
      if (!mounted || generation != _generation) return;
      state = ReportsState(
        reports: [...onto, ...page],
        loading: false,
        more: page.length >= reportsPageSize,
      );
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'load more reports', e, stack);
      if (!mounted || generation != _generation) return;
      state = ReportsState(
        reports: onto,
        loading: false,
        error: e.message,
        more: more,
      );
    }
  }
}

final reportsControllerProvider =
    StateNotifierProvider.autoDispose<ReportsController, ReportsState>(
      (ref) => ReportsController(ref),
    );
