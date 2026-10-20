// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Saving a finished export archive to disk, owned at app scope so leaving
/// Settings does not cancel it. Streams into a [DownloadTarget] like an
/// attachment download, but is keyed by export id rather than attachment.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../downloads/download_target.dart';
import '../../../downloads/downloads_controller.dart'
    show
        downloadClockProvider,
        downloadStallProvider,
        downloadTargetOpenerProvider;
import '../../../providers/providers.dart';

enum ExportSavePhase { saving, done, failed }

class ExportSave {
  const ExportSave({
    required this.phase,
    this.received = 0,
    this.total,
    this.message,
  });

  final ExportSavePhase phase;
  final int received;
  final int? total;
  final String? message;

  double? get fraction {
    final total = this.total;
    if (total == null || total <= 0) return null;
    return (received / total).clamp(0.0, 1.0).toDouble();
  }

  ExportSave copyWith({int? received, int? total}) => ExportSave(
    phase: phase,
    received: received ?? this.received,
    total: total ?? this.total,
    message: message,
  );
}

final exportSavesProvider =
    NotifierProvider<ExportSaves, Map<String, ExportSave>>(ExportSaves.new);

/// How often progress reaches the UI; chunks arrive far faster than that.
const _progressInterval = Duration(milliseconds: 150);

/// One save attempt, so a cancel or a dispose can never finish another run's file.
class _Run {
  _Run(this.target);

  final DownloadTarget target;
  StreamIterator<List<int>>? chunks;
  bool cancelled = false;
}

class ExportSaves extends Notifier<Map<String, ExportSave>> {
  final Map<String, _Run> _runs = {};
  final Set<String> _asking = {};
  int _epoch = 0;

  @override
  Map<String, ExportSave> build() {
    final session = ref.read(sessionProvider);
    final account = session.tokens?.userId;
    final sub = session.changes.listen((tokens) {
      if (tokens?.userId != account) ref.invalidateSelf();
    });
    ref.onDispose(() {
      unawaited(sub.cancel());
      _epoch++;
      for (final run in _runs.values) {
        _stop(run);
      }
      _runs.clear();
      _asking.clear();
    });
    return const {};
  }

  /// Asks where to save, then streams [job]'s archive there. A dismissed Save
  /// dialog starts nothing and is not a failure.
  Future<void> start(api.DataExport job) async {
    final id = job.id;
    if (state[id]?.phase == ExportSavePhase.saving || !_asking.add(id)) return;
    final epoch = _epoch;
    final DownloadTarget? target;
    try {
      target = await ref.read(downloadTargetOpenerProvider)(_filename(job));
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'open the export destination',
        error,
        stack,
      );
      if (epoch == _epoch) _failedSave(id, 'Could not save the export.');
      return;
    } finally {
      if (epoch == _epoch) _asking.remove(id);
    }
    if (target == null) return;
    if (epoch != _epoch) {
      await target.discard();
      return;
    }
    final limit = target.maxBytes;
    final size = job.sizeBytes;
    if (limit != null && size != null && size > limit) {
      await target.discard();
      _failedSave(id, 'This export is too large to save on this device.');
      return;
    }
    final run = _Run(target);
    _runs[id] = run;
    _set(id, ExportSave(phase: ExportSavePhase.saving, total: size));
    await _run(job, run);
  }

  /// Stops a running save and removes the partial file.
  Future<void> cancel(String exportId) async {
    final run = _runs.remove(exportId);
    _clear(exportId);
    if (run != null) await _stop(run);
  }

  void dismiss(String exportId) => _clear(exportId);

  Future<void> _stop(_Run run) async {
    run.cancelled = true;
    unawaited(run.chunks?.cancel());
    await run.target.discard();
  }

  Future<void> _run(api.DataExport job, _Run run) async {
    final id = job.id;
    try {
      final download = await ref.read(apiProvider).openExportDownload(id);
      if (run.cancelled) {
        // An unread body keeps the socket open and the server sending.
        unawaited(download.body.listen(null).cancel());
        return;
      }
      final length = download.contentLength;
      if (length != null) _update(run, id, (s) => s.copyWith(total: length));
      await _pump(id, run, download.body);
      if (run.cancelled) return;
      final saved = await run.target.finish();
      if (run.cancelled) return;
      _runs.remove(id);
      if (saved) {
        _set(id, const ExportSave(phase: ExportSavePhase.done));
      } else {
        _clear(id);
      }
    } on Object catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'save the export', e, stack);
      if (run.cancelled) return;
      _runs.remove(id);
      await run.target.discard();
      _failedSave(
        id,
        e is api.ApiException
            ? describeApiFailure('download the export', e)
            : 'Could not save the export.',
      );
    }
  }

  Future<void> _pump(String id, _Run run, Stream<List<int>> body) async {
    final chunks = StreamIterator(body);
    run.chunks = chunks;
    final clock = ref.read(downloadClockProvider);
    final stall = ref.read(downloadStallProvider);
    var received = 0;
    var shownAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      while (await chunks.moveNext().timeout(
        stall,
        onTimeout: () => throw const api.TransportException('download stalled'),
      )) {
        await run.target.write(chunks.current);
        received += chunks.current.length;
        final now = clock();
        if (now.difference(shownAt) >= _progressInterval) {
          shownAt = now;
          _update(run, id, (s) => s.copyWith(received: received));
        }
      }
      _update(run, id, (s) => s.copyWith(received: received));
    } finally {
      unawaited(chunks.cancel());
    }
  }

  String _filename(api.DataExport job) {
    final day = DateTime.fromMillisecondsSinceEpoch(
      job.createdAt,
    ).toIso8601String().substring(0, 10);
    return 'slimm-${job.kind.name}-export-$day.tar';
  }

  void _set(String id, ExportSave save) => state = {...state, id: save};

  void _clear(String id) => state = {...state}..remove(id);

  void _failedSave(String id, String message) =>
      _set(id, ExportSave(phase: ExportSavePhase.failed, message: message));

  void _update(_Run run, String id, ExportSave Function(ExportSave) change) {
    final current = state[id];
    if (current != null && !run.cancelled) _set(id, change(current));
  }
}
