// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The default [AttachmentVideoSource]: every platform other than web. See
/// `attachment_video_source.dart` for why this differs from the web sibling.
library;

import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' as api;

import 'attachment_video_source.dart';

AttachmentVideoSource createAttachmentVideoSource() =>
    _NativeAttachmentVideoSource();

class _NativeAttachmentVideoSource implements AttachmentVideoSource {
  String? _openedToken;

  @override
  Future<Media> open({
    required api.SlimmApi apiClient,
    required api.Attachment attachment,
    required void Function(double? progress) onProgress,
  }) async {
    final token = apiClient.session.tokens?.accessToken;
    if (token == null) {
      throw const api.UnauthorizedException('not signed in');
    }
    _openedToken = token;
    return Media(
      apiClient.attachmentUrl(attachment.id).toString(),
      httpHeaders: {'authorization': 'Bearer $token'},
    );
  }

  @override
  bool isStale(api.SlimmApi apiClient) =>
      _openedToken != apiClient.session.tokens?.accessToken;

  // Nothing was fetched or opened outside the player itself, which its own caller disposes.
  @override
  void dispose() {}
}
