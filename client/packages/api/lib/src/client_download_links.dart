// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'client.dart';
import 'client_transport.dart';

/// A link the browser opens as a download; it carries its own credential and lapses after a minute.
class DownloadLink {
  const DownloadLink({required this.uri, required this.expiresAt});

  final Uri uri;
  final int expiresAt;
}

/// Native browser downloads, for files too large to hold in memory.
extension SlimmApiDownloadLinks on SlimmApi {
  /// A link to an attachment; with [original] the file as uploaded.
  Future<DownloadLink> createAttachmentDownloadLink(
    String attachmentId, {
    bool original = false,
  }) =>
      _create({
        'kind': 'attachment',
        'id': attachmentId,
        if (original) 'original': true,
      });

  /// A link to a finished export archive.
  Future<DownloadLink> createExportDownloadLink(String exportId) =>
      _create({'kind': 'export', 'id': exportId});

  Future<DownloadLink> _create(Map<String, Object?> body) async {
    final json = await send('POST', '/downloads/links', body: body)
        as Map<String, dynamic>;
    return DownloadLink(
      uri: requestUri(json['path'] as String, null),
      expiresAt: json['expires_at'] as int,
    );
  }
}
