// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's data export jobs, polled while one is still being built.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// How often a running export is asked for progress; tests shrink it.
final exportPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 2),
);

/// The caller's exports, newest first. Refreshes itself while any is queued or running.
final dataExportsProvider = FutureProvider.autoDispose<List<api.DataExport>>((
  ref,
) async {
  final jobs = await ref.watch(apiProvider).listExports();
  if (jobs.any((job) => job.status.isActive)) {
    final timer = Timer(
      ref.read(exportPollIntervalProvider),
      ref.invalidateSelf,
    );
    ref.onDispose(timer.cancel);
  }
  return jobs;
});

/// The newest export of [kind] in [jobs], if any.
api.DataExport? latestExport(List<api.DataExport> jobs, api.ExportKind kind) {
  for (final job in jobs) {
    if (job.kind == kind) return job;
  }
  return null;
}
