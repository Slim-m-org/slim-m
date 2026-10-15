// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A resumable upload's server-side state, and the admin's attachment limit.
library;

/// One open resumable upload: how much of the file the server holds and the
/// largest part it will take next.
class UploadSession {
  const UploadSession({
    required this.id,
    required this.size,
    required this.offset,
    required this.partMaxBytes,
    required this.expiresAt,
  });

  final String id;
  final int size;
  final int offset;
  final int partMaxBytes;
  final int expiresAt;

  factory UploadSession.fromJson(Map<String, dynamic> json) => UploadSession(
        id: json['id'] as String,
        size: json['size'] as int,
        offset: json['offset'] as int,
        partMaxBytes: json['part_max_bytes'] as int,
        expiresAt: json['expires_at'] as int,
      );
}

/// The admin's attachment size limit beside the operator's ceiling.
class SpaceAttachmentLimit {
  const SpaceAttachmentLimit({
    required this.maxBytes,
    required this.serverMaxBytes,
  });

  /// The admin's limit, or 0 when only the operator's ceiling applies.
  final int maxBytes;
  final int serverMaxBytes;

  factory SpaceAttachmentLimit.fromJson(Map<String, dynamic> json) =>
      SpaceAttachmentLimit(
        maxBytes: json['max_bytes'] as int,
        serverMaxBytes: json['server_max_bytes'] as int,
      );
}
