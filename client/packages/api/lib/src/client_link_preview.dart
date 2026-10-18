// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Link unfurling, proxied end to end through this deployment's own server
/// rather than a client asking the linked site or its image directly - see
/// `Version.linkPreviewsEnabled` for the capability check a caller should
/// make before ever calling [fetchLinkPreview]. The `gifs` tag.
extension SlimmApiLinkPreview on SlimmApi {
  /// Unfurls [url] into its OpenGraph/title metadata, or null when the URL is
  /// well-formed but yielded no usable preview (a 404). Any other failure -
  /// malformed URL, disabled deployment, rate limit - propagates instead,
  /// since those are not "no preview", they are "could not check".
  Future<LinkPreview?> fetchLinkPreview(String url) async {
    try {
      final json = await _send('GET', '/link-preview', query: {'url': url});
      return LinkPreview.fromJson(json as Map<String, dynamic>);
    } on NotFoundException catch (error, stack) {
      AppLog.swallowed(
          LogTag.net, 'fetch link preview failed, ignored', error, stack);
      return null;
    }
  }

  /// Fetches a preview's image, streamed through this server rather than a
  /// client asking the linked site's own host directly.
  Future<FetchedBytes> fetchLinkPreviewImage(String token) =>
      _fetchBytes('/link-preview/image/$token');
}
