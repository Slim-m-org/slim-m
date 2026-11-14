// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Attachments: uploaded once, referenced by content hash on a message, and
/// the raw bytes a fetch (of either an attachment or an avatar) returns.
///
/// Split out of models.dart purely to stay under this repo's line budget; see
/// that file for how the pieces are recombined into one import.
library;

import 'dart:typed_data';

/// An attachment's metadata, as it rides along on a message or as returned
/// fresh from an upload.
class Attachment {
  const Attachment({
    required this.id,
    required this.filename,
    required this.contentType,
    required this.size,
    this.spoiler = false,
    this.original,
    this.voice,
  });

  /// Hex sha256 of the stored bytes. Also the path segment a fetch uses, and
  /// content-addressed, so the same id can legitimately ride on more than
  /// one message.
  final String id;

  /// Sanitized display name. A property of the bytes, not of any one message
  /// attaching them: the first upload of a given hash sets it.
  final String filename;

  /// One of a fixed server-side allowlist, decided by sniffing the uploaded
  /// bytes, never a client-declared header or filename extension.
  final String contentType;
  final int size;

  /// Shown behind a spoiler on the message carrying it; per message, never
  /// a property of the bytes.
  final bool spoiler;

  /// The file as uploaded, kept beside this compressed copy when the space
  /// keeps originals; fetched with `fetchAttachment`'s original flag.
  final AttachmentOriginal? original;

  /// Set when this is a voice message recorded in the composer.
  final VoiceInfo? voice;

  /// This attachment as the file that was uploaded, for saving it.
  Attachment? get asOriginal {
    final kept = original;
    if (kept == null) return null;
    return Attachment(
      id: id,
      filename: kept.filename,
      contentType: contentType,
      size: kept.size,
    );
  }

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
        id: json['id'] as String,
        filename: json['filename'] as String,
        contentType: json['content_type'] as String,
        size: json['size'] as int,
        spoiler: json['spoiler'] as bool? ?? false,
        original: json['original'] == null
            ? null
            : AttachmentOriginal.fromJson(
                json['original'] as Map<String, dynamic>,
              ),
        voice: json['voice'] == true ? VoiceInfo.fromJson(json) : null,
      );
}

/// What a voice message's player needs: its length and 64 loudness buckets.
class VoiceInfo {
  const VoiceInfo({required this.duration, required this.waveform});

  /// How many loudness buckets a waveform has.
  static const buckets = 64;

  final Duration duration;

  /// [buckets] values from 0 to 255.
  final List<int> waveform;

  /// Reads the `duration_ms` and `waveform` of an attachment object.
  factory VoiceInfo.fromJson(Map<String, dynamic> json) => VoiceInfo(
        duration: Duration(milliseconds: json['duration_ms'] as int? ?? 0),
        waveform: (json['waveform'] as List<dynamic>? ?? const [])
            .map((v) => v as int)
            .toList(growable: false),
      );
}

/// The uploaded file kept beside a compressed attachment.
class AttachmentOriginal {
  const AttachmentOriginal({required this.size, required this.filename});

  final int size;

  /// The name it was uploaded under.
  final String filename;

  factory AttachmentOriginal.fromJson(Map<String, dynamic> json) =>
      AttachmentOriginal(
        size: json['size'] as int,
        filename: json['filename'] as String,
      );
}

/// Raw bytes fetched from an octet-stream endpoint (an attachment or an
/// avatar), plus the content type the server declared for them.
///
/// Neither fetch's response body is JSON, so this is a client-side wrapper
/// around the transport reply rather than a modelled wire schema.
class FetchedBytes {
  const FetchedBytes({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

/// An attachment response whose body has not been read yet, for a caller that
/// writes it to disk as it arrives instead of holding it in memory.
///
/// Cancelling the subscription to [body] closes the connection, which is how
/// a download is stopped on the wire.
class AttachmentDownload {
  const AttachmentDownload({
    required this.body,
    required this.contentType,
    this.contentLength,
  });

  final Stream<List<int>> body;
  final String contentType;

  /// Null when the server did not say, in which case progress has no total.
  final int? contentLength;
}
