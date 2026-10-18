// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A picked attachment from the moment it appears in the composer, through
/// its upload, to whichever of ready or failed resolves.
///
/// Split out of `composer.dart`, already near its line budget: a picked file
/// has to be visible the instant it is picked, never only once its upload
/// succeeds, which needs a real model for "still uploading" and "failed,
/// retryable" rather than the plain `Attachment` list plus an `uploading`
/// bool a first version of this file held. `staged_attachment_tile.dart` is
/// the widget this model renders into, split out on its own for the same
/// line-budget reason.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../providers/providers.dart';
import '../../messages/widgets/attachment_format.dart';
import '../../../widgets/transfer_meter.dart';
import 'staged_attachment_model.dart';

export 'staged_attachment_model.dart';

/// Stages attachments for one channel's composer: a pick is visible the
/// moment it happens, its upload runs in the background, and a failure stays
/// in place until it is retried or removed rather than vanishing.
///
/// One per channel, held by [attachmentStagingProvider] for the session, so
/// what was picked in a channel is still there when that channel is reopened
/// and never rides into another one. A [ChangeNotifier] like the composer's
/// own `TextEditingController`, since the composer is its only reader.
class AttachmentStagingController extends ChangeNotifier {
  AttachmentStagingController({
    required this.upload,
    this.onFailure,
    this.onAbandon,
    this.maxBytes,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Told the resume key of a failed upload that was removed, not retried.
  final void Function(String resumeKey)? onAbandon;

  String _resumeKey(String localId) => '$_instance/$localId';

  final DateTime Function() _clock;

  /// Keeps resume keys from two controllers' `staged-1` apart.
  final int _instance = _nextInstance++;
  static int _nextInstance = 0;

  /// The server's per-attachment limit, or null when it is unknown, in which
  /// case the server is left to refuse an oversize upload itself.
  final Future<int?> Function()? maxBytes;

  /// Uploads [body], reporting bytes sent through the callback, and answers
  /// the stored attachment, or throws [api.ApiException] on failure.
  final Future<api.Attachment> Function(
    AttachmentBody body,
    String filename,
    UploadReport report,
  )
  upload;

  /// Told of every failed upload with the raw error, for the debug log.
  final void Function(String filename, Object error)? onFailure;

  final List<StagedAttachment> _items = [];
  List<StagedAttachment> get items => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  /// Whether a send has to wait: something here has not resolved to a real
  /// attachment id yet, either because it is still uploading or because it
  /// failed and needs a retry or a removal before it stops claiming a slot.
  bool get hasBlockingAttachment => _items.any((a) => a is! UploadedAttachment);

  /// The ids a send may reference. Deliberately only the uploaded ones: a
  /// caller must also check [hasBlockingAttachment] first, or a send while
  /// something is still pending would go out short of what was staged.
  List<String> get readyIds => _items
      .whereType<UploadedAttachment>()
      .map((a) => a.attachment.id)
      .toList(growable: false);

  int _nextLocalId = 0;

  final Set<String> _spoilers = {};

  /// Whether the staged item [localId] will be sent behind a spoiler.
  bool isSpoiler(String localId) => _spoilers.contains(localId);

  void toggleSpoiler(String localId) {
    if (!_spoilers.remove(localId)) _spoilers.add(localId);
    notifyListeners();
  }

  /// Stages [attachment] as already uploaded, with [bytes] purely for the
  /// tile's own local preview - the picker (`gif_picker.dart`'s own selectGif
  /// call) already stored it server-side, so there is no upload to run here,
  /// unlike [stage].
  void addResolved(api.Attachment attachment, Uint8List bytes) {
    final localId = 'staged-${_nextLocalId++}';
    _items.add(
      UploadedAttachment(
        localId: localId,
        filename: attachment.filename,
        body: AttachmentBody.memory(bytes),
        attachment: attachment,
      ),
    );
    notifyListeners();
  }

  /// Stages [bytes] and returns once it is in [items], before the upload
  /// this starts has any chance to resolve - a caller awaiting this sees the
  /// pending entry, never a gap where nothing is staged at all.
  Future<void> stage(Uint8List bytes, String filename) =>
      stageBody(AttachmentBody.memory(bytes), filename);

  /// Stages [file], first refusing it when it is over the server's limit.
  ///
  /// The tile is shown before the content is read, so a large pick appears at
  /// once. Answers the refusal sentence, or null when it was staged.
  Future<String?> stageFile(FileSource file) async {
    final length = await file.length();
    final limit = await maxBytes?.call();
    if (limit != null && length > limit) {
      final message =
          '${file.name} is ${formatByteSize(length)}, over this server\'s '
          'limit of ${formatByteSize(limit)} per file.';
      onFailure?.call(file.name, message);
      return message;
    }
    if (length <= kInMemoryAttachmentBytes) {
      await stage(await file.readAll(), file.name);
    } else {
      await stageBody(
        AttachmentBody.stream(
          length: length,
          open: file.openRead,
          openAt: file.openReadAt,
        ),
        file.name,
      );
    }
    return null;
  }

  /// [stage] for any [AttachmentBody], including a streamed one.
  Future<void> stageBody(AttachmentBody body, String filename) async {
    final localId = 'staged-${_nextLocalId++}';
    _items.add(
      UploadingAttachment(localId: localId, filename: filename, body: body),
    );
    notifyListeners();
    unawaited(_runUpload(localId, body, filename));
  }

  /// Restages a failed upload's own bytes, rather than asking the caller
  /// for a fresh pick: a browser or file-system picker cannot be replayed
  /// on its own initiative.
  void retry(String localId) {
    final index = _items.indexWhere((a) => a.localId == localId);
    final current = index == -1 ? null : _items[index];
    if (current is! FailedAttachment) return;
    _items[index] = UploadingAttachment(
      localId: localId,
      filename: current.filename,
      body: current.body,
    );
    notifyListeners();
    unawaited(_runUpload(localId, current.body, current.filename));
  }

  /// Hands the uploaded ids to [send], taking them out of the staging in the
  /// same synchronous step so a second send finds nothing left to post. They
  /// go back if [send] throws before the message was queued.
  Future<void> sendReady(Future<void> Function(StagedSend staged) send) async {
    final taken = _items.whereType<UploadedAttachment>().toList();
    if (taken.isNotEmpty) {
      _items.removeWhere((a) => a is UploadedAttachment);
      notifyListeners();
    }
    try {
      await send(
        StagedSend(
          [for (final a in taken) a.attachment.id],
          spoilerIds: [
            for (final a in taken)
              if (_spoilers.contains(a.localId)) a.attachment.id,
          ],
        ),
      );
      _spoilers.removeAll([for (final a in taken) a.localId]);
    } on Object {
      _items.insertAll(0, taken);
      notifyListeners();
      rethrow;
    }
  }

  void remove(String localId) {
    for (final a in _items.where((a) => a.localId == localId)) {
      _drop(a);
    }
    _items.removeWhere((a) => a.localId == localId);
    _spoilers.remove(localId);
    notifyListeners();
  }

  void _cancelIfUploading(StagedAttachment a) {
    if (a is UploadingAttachment) a.body.cancel.cancel();
  }

  /// For an explicit remove, never teardown: a failed file's kept session goes.
  void _drop(StagedAttachment a) {
    _cancelIfUploading(a);
    if (a is FailedAttachment) onAbandon?.call(_resumeKey(a.localId));
  }

  @override
  void dispose() {
    _items.forEach(_cancelIfUploading);
    super.dispose();
  }

  void clear() {
    _items.forEach(_drop);
    _items.clear();
    _spoilers.clear();
    notifyListeners();
  }

  Future<void> _runUpload(
    String localId,
    AttachmentBody body,
    String filename,
  ) async {
    final meter = TransferMeter(_clock);
    var sent = 0;
    var reconnecting = false;
    void show() => _replace(
      localId,
      UploadingAttachment(
        localId: localId,
        filename: filename,
        body: body,
        sent: sent,
        meter: meter,
        reconnecting: reconnecting,
      ),
      onlyWhileUploading: true,
    );
    try {
      final attachment = await upload(
        body,
        filename,
        UploadReport(
          resumeKey: _resumeKey(localId),
          onProgress: (bytes) {
            sent = bytes;
            meter.record(bytes);
            show();
          },
          onRetrying: (retrying) {
            // The old link's speed says nothing about the one after a reconnect.
            if (retrying) meter.reset();
            reconnecting = retrying;
            show();
          },
        ),
      );
      _replace(
        localId,
        UploadedAttachment(
          localId: localId,
          // The server's own name: content addressing can answer with a different one.
          filename: attachment.filename,
          body: body,
          attachment: attachment,
        ),
      );
    } on api.UploadCancelled catch (_) {
      api.AppLog.debug(api.LogTag.media, 'An upload was cancelled');
      return;
    } on Object catch (e) {
      onFailure?.call(filename, e);
      _replace(
        localId,
        FailedAttachment(
          localId: localId,
          filename: filename,
          body: body,
          message: e is api.ApiException
              ? describeApiFailure('attach the file', e)
              : 'Could not attach the file.',
        ),
      );
    }
  }

  /// A no-op if [localId] was removed while its upload was still in flight.
  void _replace(
    String localId,
    StagedAttachment next, {
    bool onlyWhileUploading = false,
  }) {
    final index = _items.indexWhere((a) => a.localId == localId);
    if (index == -1) return;
    if (onlyWhileUploading && _items[index] is! UploadingAttachment) return;
    _items[index] = next;
    notifyListeners();
  }
}

/// The staging for one channel, alive for the whole session like the text
/// drafts in `channel_drafts.dart`: a picked file is back on the composer
/// when its channel is reopened, whether the screen switched channels or was
/// torn down for voice, a call or the canvas. In memory only - the bytes are
/// for the tile's preview and the server sweeps an unsent upload after a day,
/// so a restart starts clean. A different account signing in on this process
/// empties every channel's staging, the same boundary the drafts keep.
final attachmentStagingProvider =
    Provider.family<AttachmentStagingController, String>((ref, channelId) {
      final controller = AttachmentStagingController(
        upload: (body, filename, report) async {
          final client = ref.read(apiProvider);
          return client.uploadAttachmentAuto(
            body.source,
            length: body.length,
            capabilities: await _serverCapabilities(ref, body.length),
            filename: filename,
            channelId: channelId,
            onProgress: report.call,
            onRetrying: report.onRetrying,
            resumeKey: report.resumeKey,
            cancel: body.cancel,
          );
        },
        onAbandon: (key) => ref.read(apiProvider).abandonUpload(key),
        maxBytes: () => _attachmentLimit(ref),
        onFailure: (filename, error) => api.AppLog.warning(
          api.LogTag.media,
          'Could not upload $filename',
          error: error,
        ),
      );
      final session = ref.read(sessionProvider);
      final account = session.tokens?.userId;
      final sub = session.changes.listen((tokens) {
        if (tokens?.userId != account) ref.invalidateSelf();
      });
      ref.onDispose(() {
        sub.cancel();
        controller.dispose();
      });
      return controller;
    });

/// What the server advertises, asked only for a file big enough to need it,
/// and null when it cannot be learned quickly so the plain upload is used.
Future<List<String>?> _serverCapabilities(Ref ref, int length) async {
  if (length <= api.kUploadSessionThreshold) return null;
  try {
    final version = await ref
        .read(apiProvider)
        .version()
        .timeout(const Duration(seconds: 3));
    return version.capabilities;
  } on Object catch (error, stack) {
    api.reportFailure(
      api.LogTag.media,
      "read the server's upload limits",
      error,
      stack,
    );
    return null;
  }
}

/// The server's per-file ceiling from `/version`, or null when it cannot be
/// learned quickly, so a flaky link never holds a pick up.
Future<int?> _attachmentLimit(Ref ref) async {
  try {
    final version = await ref
        .read(apiProvider)
        .version()
        .timeout(const Duration(seconds: 3));
    return version.maxAttachmentBytes;
  } on Object catch (error, stack) {
    api.reportFailure(
      api.LogTag.media,
      "read the server's attachment size limit",
      error,
      stack,
    );
    return null;
  }
}
