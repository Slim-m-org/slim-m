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
    show downloadStallProvider, downloadTargetOpenerProvider;
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

class ExportSaves extends Notifier<Map<String, ExportSave>> {
  final Map<String, StreamIterator<List<int>>> _open = {};
  final Set<String> _cancelled = {};

  @override
  Map<String, ExportSave> build() {
    final session = ref.read(sessionProvider);
    final account = session.tokens?.userId;
    final sub = session.changes.listen((tokens) {
      if (tokens?.userId != account) ref.invalidateSelf();
    });
    ref.onDispose(() {
      unawaited(sub.cancel());
      for (final chunks in _open.values) {
        unawaited(chunks.cancel());
      }
      _open.clear();
    });
    return const {};
  }

  /// Asks where to save, then streams [job]'s archive there. A dismissed Save
  /// dialog starts nothing and is not a failure.
  Future<void> start(api.DataExport job) async {
    if (state[job.id]?.phase == ExportSavePhase.saving) return;
    final filename = _filename(job);
    final DownloadTarget? target;
    try {
      target = await ref.read(downloadTargetOpenerProvider)(filename);
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'open the export destination',
        error,
        stack,
      );
      _set(
        job.id,
        const ExportSave(
          phase: ExportSavePhase.failed,
          message: 'Could not save the export.',
        ),
      );
      return;
    }
    if (target == null) return;
    _cancelled.remove(job.id);
    _set(
      job.id,
      ExportSave(phase: ExportSavePhase.saving, total: job.sizeBytes),
    );
    await _run(job, target);
  }

  /// Stops a running save and removes the partial file.
  Future<void> cancel(String exportId) async {
    _cancelled.add(exportId);
    unawaited(_open.remove(exportId)?.cancel());
    _clear(exportId);
  }

  void dismiss(String exportId) => _clear(exportId);

  Future<void> _run(api.DataExport job, DownloadTarget target) async {
    try {
      final download = await ref.read(apiProvider).openExportDownload(job.id);
      final length = download.contentLength;
      if (length != null) _update(job.id, (s) => s.copyWith(total: length));
      await _pump(job.id, target, download.body);
      if (_cancelled.contains(job.id)) {
        await target.discard();
        return;
      }
      final saved = await target.finish();
      if (saved) {
        _set(job.id, const ExportSave(phase: ExportSavePhase.done));
      } else {
        _clear(job.id);
      }
    } on Object catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'save the export', e, stack);
      await target.discard();
      if (_cancelled.contains(job.id)) return;
      _set(
        job.id,
        ExportSave(
          phase: ExportSavePhase.failed,
          message: e is api.ApiException
              ? describeApiFailure('download the export', e)
              : 'Could not save the export.',
        ),
      );
    }
  }

  Future<void> _pump(
    String id,
    DownloadTarget target,
    Stream<List<int>> body,
  ) async {
    final chunks = StreamIterator(body);
    _open[id] = chunks;
    final stall = ref.read(downloadStallProvider);
    var received = 0;
    try {
      while (await chunks.moveNext().timeout(
        stall,
        onTimeout: () => throw const api.TransportException('download stalled'),
      )) {
        await target.write(chunks.current);
        received += chunks.current.length;
        _update(id, (s) => s.copyWith(received: received));
      }
    } finally {
      _open.remove(id);
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

  void _update(String id, ExportSave Function(ExportSave) change) {
    final current = state[id];
    if (current != null) _set(id, change(current));
  }
}
