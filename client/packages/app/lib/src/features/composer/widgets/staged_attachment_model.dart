// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The staged-attachment model: bodies, sources and the sealed staged states.
library;

import 'package:flutter/foundation.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../widgets/transfer_meter.dart';

/// What an upload reads from: held bytes for a small pick, or a re-openable
/// stream for a file too big to hold, so a 5 GB pick never lands in memory.
///
/// [open] is a factory because a retry, or the refresh after a 401, reads the
/// body again from the start.
class AttachmentBody {
  AttachmentBody.memory(Uint8List this.bytes)
    : length = bytes.length,
      open = (() => Stream.value(bytes)),
      openAt = null;

  AttachmentBody.stream({required this.length, required this.open, this.openAt})
    : bytes = null;

  final int length;

  /// Null for a streamed body, which has no preview to draw.
  final Uint8List? bytes;
  final Stream<List<int>> Function() open;

  /// Reads from a byte offset, where the source can seek; otherwise a resumed
  /// upload re-reads [open] up to the offset.
  final Stream<List<int>> Function(int offset)? openAt;

  /// Stops a resumable upload of this body when its tile goes away.
  final api.UploadCancelToken cancel = api.UploadCancelToken();

  api.UploadSource get source => api.UploadSource(open: open, openAt: openAt);
}

/// A picked or dropped file, read only when it is staged: its size is known
/// up front, and its content is read whole or streamed depending on that size.
class FileSource {
  const FileSource({
    required this.name,
    required this.length,
    required this.readAll,
    required this.openRead,
    this.openReadAt,
  });

  final String name;
  final Future<int> Function() length;
  final Future<Uint8List> Function() readAll;
  final Stream<List<int>> Function() openRead;
  final Stream<List<int>> Function(int offset)? openReadAt;
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
    this.meter,
    this.reconnecting = false,
  });

  final int sent;

  /// The connection dropped and the upload is retrying from where it got to.
  final bool reconnecting;

  /// Speed and time left; null where nothing measures it.
  final TransferMeter? meter;

  /// 0 to 1, for a progress bar.
  double get fraction =>
      body.length == 0 ? 0 : (sent / body.length).clamp(0.0, 1.0);
}

/// What an upload reports back while it runs. Callable as the progress
/// callback itself; [resumeKey] names this staged file across retries, so a
/// retry carries on from where a failed upload stopped.
class UploadReport {
  const UploadReport({
    required this.resumeKey,
    required void Function(int sent) onProgress,
    required this.onRetrying,
  }) : _onProgress = onProgress;

  final String resumeKey;
  final void Function(int sent) _onProgress;
  final void Function(bool retrying) onRetrying;

  void call(int sent) => _onProgress(sent);
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
/// [looksLikeImage]'s twin for video, for offering a spoiler before upload.
bool looksLikeVideo(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0) return false;
  const videoExtensions = {'.mp4', '.webm', '.mov', '.mkv', '.m4v'};
  return videoExtensions.contains(filename.substring(dot).toLowerCase());
}

bool looksLikeImage(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot == -1) return false;
  const imageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp'};
  return imageExtensions.contains(filename.substring(dot).toLowerCase());
}

/// What a send takes from the staging: the uploaded ids in display order,
/// and which of them go behind a spoiler.
class StagedSend {
  const StagedSend(this.ids, {this.spoilerIds = const []});

  final List<String> ids;
  final List<String> spoilerIds;
}
