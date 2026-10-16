// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Attachment downloads, owned at app scope.
///
/// Nothing here belongs to a widget: a download keeps running when the user
/// switches channels, and the transfers banner reads it from anywhere. Each
/// run streams the response into a [DownloadTarget] and can be cancelled,
/// which closes the connection (the server stops reading the file when the
/// socket goes) and deletes the partial file.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../api_failure.dart';
import '../providers/providers.dart';
import '../widgets/transfer_meter.dart';
import 'download_target.dart';

enum DownloadPhase { running, failed, done }

class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.attachment,
    required this.meter,
    this.received = 0,
    this.total,
    this.phase = DownloadPhase.running,
    this.message,
  });

  final int id;
  final api.Attachment attachment;
  final TransferMeter meter;
  final int received;

  /// Null when the server sent no length.
  final int? total;
  final DownloadPhase phase;

  /// The failure sentence, for [DownloadPhase.failed].
  final String? message;

  bool get running => phase == DownloadPhase.running;

  DownloadTask copyWith({
    int? received,
    int? total,
    DownloadPhase? phase,
    String? message,
  }) => DownloadTask(
    id: id,
    attachment: attachment,
    meter: meter,
    received: received ?? this.received,
    total: total ?? this.total,
    phase: phase ?? this.phase,
    message: message ?? this.message,
  );
}

/// Read for every meter and throttle, so tests can drive the clock.
final downloadClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// How long a download may go without a byte before it fails; tests shrink it.
final downloadStallProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 60),
);

/// The Save dialog, overridable in tests.
final downloadTargetOpenerProvider = Provider<DownloadTargetOpener>(
  (ref) => openDownloadTarget,
);

final downloadsProvider =
    NotifierProvider<DownloadsController, List<DownloadTask>>(
      DownloadsController.new,
    );

/// How often progress reaches the UI; chunks arrive far faster than that.
const _progressInterval = Duration(milliseconds: 150);

class _Run {
  _Run(this.target);

  final DownloadTarget target;
  StreamIterator<List<int>>? chunks;
  bool cancelled = false;
}

class DownloadsController extends Notifier<List<DownloadTask>> {
  final Map<int, _Run> _runs = {};
  int _nextId = 0;

  /// Attachments whose Save dialog is open, so a second click opens no second one.
  final Set<String> _asking = {};

  @override
  List<DownloadTask> build() {
    // A run belongs to the account that started it: a different sign-in rebuilds this and cancels them.
    final session = ref.read(sessionProvider);
    final account = session.tokens?.userId;
    final sub = session.changes.listen((tokens) {
      if (tokens?.userId != account) ref.invalidateSelf();
    });
    ref.onDispose(() {
      unawaited(sub.cancel());
      for (final run in _runs.values) {
        run.cancelled = true;
        unawaited(run.chunks?.cancel());
        unawaited(run.target.discard());
      }
      _runs.clear();
    });
    return const [];
  }

  /// Whether [attachmentId] is downloading right now.
  bool isDownloading(String attachmentId) =>
      _asking.contains(attachmentId) ||
      state.any((t) => t.running && t.attachment.id == attachmentId);

  /// Asks where to save, then downloads in the background. A dismissed Save
  /// dialog is not a failure and starts nothing.
  Future<void> start(api.Attachment attachment) async {
    if (isDownloading(attachment.id)) return;
    _asking.add(attachment.id);
    final DownloadTarget? target;
    try {
      target = await ref.read(downloadTargetOpenerProvider)(
        attachment.filename,
      );
    } on Object {
      _add(_failed(attachment, 'Could not save ${attachment.filename}.'));
      return;
    } finally {
      _asking.remove(attachment.id);
    }
    if (target == null) return;
    final limit = target.maxBytes;
    if (limit != null && attachment.size > limit) {
      await target.discard();
      _add(
        _failed(
          attachment,
          '${attachment.filename} is too large to save on this device.',
        ),
      );
      return;
    }
    final id = _nextId++;
    final run = _Run(target);
    _runs[id] = run;
    state = [
      // Finished rows go, and so does this attachment's old failure: a retry replaces it.
      for (final t in state)
        if (t.running ||
            (t.phase == DownloadPhase.failed &&
                t.attachment.id != attachment.id))
          t,
      DownloadTask(
        id: id,
        attachment: attachment,
        meter: TransferMeter(ref.read(downloadClockProvider)),
        total: attachment.size > 0 ? attachment.size : null,
      ),
    ];
    await _run(id, run, attachment);
  }

  /// Stops a running download and removes its partial file.
  Future<void> cancel(int id) async {
    final run = _runs.remove(id);
    if (run == null) return;
    run.cancelled = true;
    state = [
      for (final t in state)
        if (t.id != id) t,
    ];
    unawaited(run.chunks?.cancel());
    await run.target.discard();
  }

  void dismiss(int id) {
    state = [
      for (final t in state)
        if (t.id != id) t,
    ];
  }

  Future<void> _run(int id, _Run run, api.Attachment attachment) async {
    try {
      final download = await ref
          .read(apiProvider)
          .openAttachmentDownload(attachment.id);
      if (run.cancelled) {
        // An unread body keeps the socket open and the server sending.
        unawaited(download.body.listen(null).cancel());
        return;
      }
      final length = download.contentLength;
      if (length != null) _update(id, (t) => t.copyWith(total: length));
      await _pump(id, run, download.body);
      if (run.cancelled) return;
      final saved = await run.target.finish();
      _runs.remove(id);
      if (saved) {
        _update(id, (t) => t.copyWith(phase: DownloadPhase.done));
      } else {
        dismiss(id);
      }
    } on Object catch (e) {
      if (run.cancelled) return;
      _runs.remove(id);
      await run.target.discard();
      _update(
        id,
        (t) => t.copyWith(
          phase: DownloadPhase.failed,
          message: e is api.ApiException
              ? describeApiFailure('download ${attachment.filename}', e)
              : 'Could not save ${attachment.filename}.',
        ),
      );
    }
  }

  Future<void> _pump(int id, _Run run, Stream<List<int>> body) async {
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
        state.where((t) => t.id == id).firstOrNull?.meter.record(received);
        final now = clock();
        if (now.difference(shownAt) >= _progressInterval) {
          shownAt = now;
          _update(id, (t) => t.copyWith(received: received));
        }
      }
      _update(id, (t) => t.copyWith(received: received));
    } finally {
      // Any exit, normal or not, must close the connection.
      unawaited(chunks.cancel());
    }
  }

  void _update(int id, DownloadTask Function(DownloadTask) change) {
    state = [for (final t in state) t.id == id ? change(t) : t];
  }

  void _add(DownloadTask task) => state = [...state, task];

  DownloadTask _failed(api.Attachment attachment, String message) =>
      DownloadTask(
        id: _nextId++,
        attachment: attachment,
        meter: TransferMeter(),
        phase: DownloadPhase.failed,
        message: message,
      );
}
