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
import '../providers/providers.dart';

/// One attachment as the composer sees it, from the moment its bytes are
/// picked. [bytes] and [filename] never change once staged; a retry restages
/// the same bytes rather than asking wherever they came from for a fresh
/// read, since a picker or a clipboard cannot be replayed on demand.
sealed class StagedAttachment {
  const StagedAttachment({
    required this.localId,
    required this.filename,
    required this.bytes,
  });

  /// A client-only id: nothing here is uploaded yet when one is minted, so
  /// it cannot be the server's own content hash.
  final String localId;
  final String filename;
  final Uint8List bytes;
}

/// Picked, and the upload has not yet resolved either way.
class UploadingAttachment extends StagedAttachment {
  const UploadingAttachment({
    required super.localId,
    required super.filename,
    required super.bytes,
  });
}

/// Uploaded: [attachment] is what a send may reference.
class UploadedAttachment extends StagedAttachment {
  const UploadedAttachment({
    required super.localId,
    required super.filename,
    required super.bytes,
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
    required super.bytes,
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
  AttachmentStagingController({required this.upload});

  /// Uploads bytes and answers the stored attachment, or throws
  /// [api.ApiException] on failure, the same contract
  /// `SlimmApiAttachments.uploadAttachment` already has.
  final Future<api.Attachment> Function(Uint8List bytes, String filename)
  upload;

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
        bytes: bytes,
        attachment: attachment,
      ),
    );
    notifyListeners();
  }

  /// Stages [bytes] and returns once it is in [items], before the upload
  /// this starts has any chance to resolve - a caller awaiting this sees the
  /// pending entry, never a gap where nothing is staged at all.
  Future<void> stage(Uint8List bytes, String filename) async {
    final localId = 'staged-${_nextLocalId++}';
    _items.add(
      UploadingAttachment(localId: localId, filename: filename, bytes: bytes),
    );
    notifyListeners();
    unawaited(_runUpload(localId, bytes, filename));
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
      bytes: current.bytes,
    );
    notifyListeners();
    unawaited(_runUpload(localId, current.bytes, current.filename));
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
    Uint8List bytes,
    String filename,
  ) async {
    try {
      final attachment = await upload(bytes, filename);
      _replace(
        localId,
        UploadedAttachment(
          localId: localId,
          // The server's own name: content addressing can answer with a different one.
          filename: attachment.filename,
          bytes: bytes,
          attachment: attachment,
        ),
      );
    } on api.ApiException catch (e) {
      _replace(
        localId,
        FailedAttachment(
          localId: localId,
          filename: filename,
          bytes: bytes,
          message: describeApiFailure('attach the file', e),
        ),
      );
    }
  }

  /// A no-op if [localId] was removed while its upload was still in flight.
  void _replace(String localId, StagedAttachment next) {
    final index = _items.indexWhere((a) => a.localId == localId);
    if (index == -1) return;
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
        upload: (bytes, filename) =>
            ref.read(apiProvider).uploadAttachment(bytes, filename: filename),
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
