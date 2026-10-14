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

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
        id: json['id'] as String,
        filename: json['filename'] as String,
        contentType: json['content_type'] as String,
        size: json['size'] as int,
        spoiler: json['spoiler'] as bool? ?? false,
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
