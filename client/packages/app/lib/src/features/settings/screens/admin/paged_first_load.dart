// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first load of a paged admin list (audit log, debug logs, reports and
/// their history), as the three states [AppAsyncView] draws.
library;

import 'package:slimm_design_system/design_system.dart';

/// A spinner or the failure on its own until a page has landed, never an empty list nobody fetched.
///
/// A later failure, with pages held, is the load-more row's to show.
AppAsyncState<List<T>> pagedFirstLoad<T>(
  List<T> items, {
  required bool loading,
  required Object? failure,
}) => AppAsyncState(
  data: items.isEmpty && (loading || failure != null) ? null : items,
  error: items.isEmpty ? failure : null,
);
