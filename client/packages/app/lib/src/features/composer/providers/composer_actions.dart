// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The upload, GIF and poll writes the composer widgets make, so none of them talks to REST.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

class ComposerActions {
  const ComposerActions(this._api);

  final SlimmApi _api;

  void abandonUpload(String resumeKey) => _api.abandonUpload(resumeKey);

  Future<Attachment> uploadAttachmentAuto(
    UploadSource source, {
    required int length,
    required List<String>? capabilities,
    String? filename,
    String? channelId,
    void Function(int sent)? onProgress,
    void Function(bool retrying)? onRetrying,
    UploadCancelToken? cancel,
    String? resumeKey,
  }) => _api.uploadAttachmentAuto(
    source,
    length: length,
    capabilities: capabilities,
    filename: filename,
    channelId: channelId,
    onProgress: onProgress,
    onRetrying: onRetrying,
    cancel: cancel,
    resumeKey: resumeKey,
  );

  Future<FetchedBytes> fetchAttachment(
    String attachmentId, {
    int? previewWidth,
    bool firstFrame = false,
  }) => _api.fetchAttachment(
    attachmentId,
    previewWidth: previewWidth,
    firstFrame: firstFrame,
  );

  Future<List<GifResult>> searchGifs(
    String query, {
    int? limit,
    String? channelId,
  }) => _api.searchGifs(query, limit: limit, channelId: channelId);

  Future<Attachment> selectGif(String gifId, {String? channelId}) =>
      _api.selectGif(gifId, channelId: channelId);

  Future<Message> sendPollMessage({
    required String channelId,
    required String id,
    required String question,
    required List<String> options,
    String? content,
    int? closeAt,
    bool ranked = false,
  }) => _api.sendPollMessage(
    channelId: channelId,
    id: id,
    question: question,
    options: options,
    content: content,
    closeAt: closeAt,
    ranked: ranked,
  );
}

final composerActionsProvider = Provider(
  (ref) => ComposerActions(ref.watch(apiProvider)),
);
