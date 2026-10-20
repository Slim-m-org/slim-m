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

class _PollState {
  int failures = 0;
  bool polling = false;
}

/// Outlives each refresh, so a failed poll knows an export was being watched.
final _pollStateProvider = Provider<_PollState>((ref) => _PollState());

const _maxBackoffDoublings = 4;

/// The caller's exports, newest first. Refreshes itself while any is queued or
/// running, and keeps asking, with a growing delay, when such a poll fails.
final dataExportsProvider = FutureProvider.autoDispose<List<api.DataExport>>((
  ref,
) async {
  Timer? timer;
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    timer?.cancel();
  });
  void schedule(Duration delay) {
    if (!disposed) timer = Timer(delay, ref.invalidateSelf);
  }

  final poll = ref.read(_pollStateProvider);
  final interval = ref.read(exportPollIntervalProvider);
  try {
    final jobs = await ref.watch(apiProvider).listExports();
    poll.failures = 0;
    poll.polling = jobs.any((job) => job.status.isActive);
    if (poll.polling) schedule(interval);
    return jobs;
  } on Object {
    if (poll.polling) {
      schedule(interval * (1 << poll.failures.clamp(0, _maxBackoffDoublings)));
      poll.failures++;
    }
    rethrow;
  }
});

/// The newest export of [kind] in [jobs], if any.
api.DataExport? latestExport(List<api.DataExport> jobs, api.ExportKind kind) {
  for (final job in jobs) {
    if (job.kind == kind) return job;
  }
  return null;
}
