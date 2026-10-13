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

import '../api_failure.dart';
import '../diagnostics/debug_log.dart';
import '../providers/providers.dart';
import 'attachment_format.dart';

/// What an upload reads from: held bytes for a small pick, or a re-openable
/// stream for a file too big to hold, so a 5 GB pick never lands in memory.
///
/// [open] is a factory because a retry, or the refresh after a 401, reads the
/// body again from the start.
class AttachmentBody {
  AttachmentBody.memory(Uint8List this.bytes)
    : length = bytes.length,
      open = (() => Stream.value(bytes));

  const AttachmentBody.stream({required this.length, required this.open})
    : bytes = null;

  final int length;

  /// Null for a streamed body, which has no preview to draw.
  final Uint8List? bytes;
  final Stream<List<int>> Function() open;
}

/// A picked or dropped file, read only when it is staged: its size is known
/// up front, and its content is read whole or streamed depending on that size.
class FileSource {
  const FileSource({
    required this.name,
    required this.length,
    required this.readAll,
    required this.openRead,
  });

  final String name;
  final Future<int> Function() length;
  final Future<Uint8List> Function() readAll;
  final Stream<List<int>> Function() openRead;
}

/// Files up to this size are read whole, which also gives them a preview;
/// anything larger is streamed from disk so it never sits in memory.
const kInMemoryAttachmentBytes = 8 * 1024 * 1024;

/// One attachment as the composer sees it, from the moment it is picked.
/// [body] and [filename] never change once staged; a retry restages the same
/// body rather than asking wherever it came from for a fresh read, since a
/// picker or a clipboard cannot be replayed on demand.
sealed class StagedAttachment {
  const StagedAttachment({
    required this.localId,
    required this.filename,
    required this.body,
  });

  /// A client-only id: nothing here is uploaded yet when one is minted, so
  /// it cannot be the server's own content hash.
  final String localId;
  final String filename;
  final AttachmentBody body;

  Uint8List? get bytes => body.bytes;
}

/// Picked, and the upload has not yet resolved either way. [sent] is how many
/// of the body's bytes have been handed to the network so far.
class UploadingAttachment extends StagedAttachment {
  const UploadingAttachment({
    required super.localId,
    required super.filename,
    required super.body,
    this.sent = 0,
  });

  final int sent;

  /// 0 to 1, for a progress bar.
  double get fraction =>
      body.length == 0 ? 0 : (sent / body.length).clamp(0.0, 1.0);
}

/// Uploaded: [attachment] is what a send may reference.
class UploadedAttachment extends StagedAttachment {
  const UploadedAttachment({
    required super.localId,
    required super.filename,
    required super.body,
    required this.attachment,
  });

  final api.Attachment attachment;
}

/// The upload failed. [message] is already a plain sentence from
/// [describeApiFailure], never the raw exception.
class FailedAttachment extends StagedAttachment {
  const FailedAttachment({
    required super.localId,
    required super.filename,
    required super.body,
    required this.message,
  });

  final String message;
}

/// A small, deliberately client-only guess at whether [filename] is worth a
/// thumbnail.
///
/// The server sniffs the real content type after upload (see `media.rs`);
/// this only decides what is worth *trying* to draw before that answer
/// exists, and `StagedAttachmentTile`'s `errorBuilder` is what a wrong guess
/// falls back to.
bool looksLikeImage(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot == -1) return false;
  const imageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp'};
  return imageExtensions.contains(filename.substring(dot).toLowerCase());
}

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
    this.maxBytes,
  });

  /// The server's per-attachment limit, or null when it is unknown, in which
  /// case the server is left to refuse an oversize upload itself.
  final Future<int?> Function()? maxBytes;

  /// Uploads [body], reporting bytes sent through the callback, and answers
  /// the stored attachment, or throws [api.ApiException] on failure.
  final Future<api.Attachment> Function(
    AttachmentBody body,
    String filename,
    void Function(int sent) onProgress,
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
        AttachmentBody.stream(length: length, open: file.openRead),
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
  Future<void> sendReady(Future<void> Function(List<String> ids) send) async {
    final taken = _items.whereType<UploadedAttachment>().toList();
    if (taken.isNotEmpty) {
      _items.removeWhere((a) => a is UploadedAttachment);
      notifyListeners();
    }
    try {
      await send([for (final a in taken) a.attachment.id]);
    } on Object {
      _items.insertAll(0, taken);
      notifyListeners();
      rethrow;
    }
  }

  void remove(String localId) {
    _items.removeWhere((a) => a.localId == localId);
    notifyListeners();
  }

  void clear() {
    _items.clear();
    notifyListeners();
  }

  Future<void> _runUpload(
    String localId,
    AttachmentBody body,
    String filename,
  ) async {
    try {
      final attachment = await upload(
        body,
        filename,
        (sent) => _replace(
          localId,
          UploadingAttachment(
            localId: localId,
            filename: filename,
            body: body,
            sent: sent,
          ),
          onlyWhileUploading: true,
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
        upload: (body, filename, onProgress) => ref
            .read(apiProvider)
            .uploadAttachmentStream(
              body.open,
              length: body.length,
              filename: filename,
              onProgress: onProgress,
            ),
        maxBytes: () => _attachmentLimit(ref),
        onFailure: (filename, error) => ref
            .read(debugLogProvider.notifier)
            .record('attachment', 'Upload of $filename failed', detail: error),
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

/// The server's per-file ceiling from `/version`, or null when it cannot be
/// learned quickly, so a flaky link never holds a pick up.
Future<int?> _attachmentLimit(Ref ref) async {
  try {
    final version = await ref
        .read(apiProvider)
        .version()
        .timeout(const Duration(seconds: 3));
    return version.maxAttachmentBytes;
  } on Object {
    return null;
  }
}
