// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web [AttachmentVideoSource]. See `attachment_video_source.dart` for
/// why this fetches the whole attachment rather than streaming it the way
/// the native platforms do.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:web/web.dart' as web;

import 'attachment_video_source.dart';

AttachmentVideoSource createAttachmentVideoSource() =>
    _WebAttachmentVideoSource();

class _WebAttachmentVideoSource implements AttachmentVideoSource {
  web.XMLHttpRequest? _request;
  String? _blobUrl;

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
    final bytes = await _fetch(
      apiClient.attachmentUrl(attachment.id),
      token,
      onProgress,
    );
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: attachment.contentType),
    );
    final url = web.URL.createObjectURL(blob);
    _blobUrl = url;
    return Media(url);
  }

  /// A raw `XMLHttpRequest`, not the app's own `package:http` transport: this
  /// needs `onprogress`, which the app's transport does not expose, and
  /// running outside it means an access-token rotation mid-fetch is not
  /// retried the way an ordinary request is - acceptable for a single
  /// attachment fetch, whose whole point is to finish quickly.
  Future<Uint8List> _fetch(
    Uri url,
    String token,
    void Function(double? progress) onProgress,
  ) {
    final completer = Completer<Uint8List>();
    final xhr = web.XMLHttpRequest();
    _request = xhr;
    xhr.open('GET', url.toString(), true);
    xhr.responseType = 'arraybuffer';
    xhr.setRequestHeader('authorization', 'Bearer $token');
    xhr.onprogress = ((web.Event event) {
      final progress = event as web.ProgressEvent;
      onProgress(
        progress.lengthComputable ? progress.loaded / progress.total : null,
      );
    }).toJS;
    xhr.onload = ((web.Event event) {
      if (xhr.status >= 200 && xhr.status < 300) {
        final buffer = (xhr.response as JSArrayBuffer).toDart;
        completer.complete(buffer.asUint8List());
      } else {
        completer.completeError(
          api.TransportException('attachment fetch failed: HTTP ${xhr.status}'),
        );
      }
    }).toJS;
    xhr.onerror = ((web.Event event) {
      completer.completeError(
        const api.TransportException('attachment fetch failed: network error'),
      );
    }).toJS;
    xhr.send();
    return completer.future;
  }

  // The whole file is fetched up front, so no later request carries a token.
  @override
  bool isStale(api.SlimmApi apiClient) => false;

  @override
  void dispose() {
    _request?.abort();
    final url = _blobUrl;
    if (url != null) web.URL.revokeObjectURL(url);
  }
}
