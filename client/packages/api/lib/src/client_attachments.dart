// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Attachments: upload bytes once, reference the returned id in
/// [SlimmApi.sendMessage], fetch them back. The `attachments` tag.
extension SlimmApiAttachments on SlimmApi {
  /// Uploads an attachment's raw [bytes]. Idempotent by content: uploading
  /// bytes that already exist returns the existing id rather than storing a
  /// second copy. An id never referenced by a message is reclaimed
  /// automatically after a day, so upload right before sending rather than
  /// far ahead of it.
  Future<Attachment> uploadAttachment(
    List<int> bytes, {
    String? filename,
  }) async {
    final json = await _send(
      'POST',
      '/attachments',
      bytes: bytes,
      query: filename == null ? null : {'filename': filename},
    );
    return Attachment.fromJson(json as Map<String, dynamic>);
  }

  /// Uploads [length] bytes read from [open] without holding them in memory,
  /// calling [onProgress] with the running byte count as they are consumed.
  ///
  /// [open] is a factory, not a stream: the one-shot refresh-and-replay after
  /// a 401 has to read the body again from the start.
  Future<Attachment> uploadAttachmentStream(
    Stream<List<int>> Function() open, {
    required int length,
    String? filename,
    void Function(int sent)? onProgress,
    bool isRetry = false,
  }) async {
    final token = session.tokens?.accessToken;
    if (token == null) throw const UnauthorizedException('not signed in');
    final request = http.StreamedRequest(
      'POST',
      _requestUri(
        '/attachments',
        filename == null ? null : {'filename': filename},
      ),
    )
      ..contentLength = length
      ..headers['content-type'] = 'application/octet-stream'
      ..headers['authorization'] = 'Bearer $token';
    var sent = 0;
    final body = open().map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent);
      return chunk;
    });
    unawaited(
      request.sink
          .addStream(body)
          .then((_) => request.sink.close())
          .catchError((Object e, StackTrace st) {
        request.sink.addError(e, st);
        request.sink.close();
      }),
    );
    final http.Response response;
    try {
      final streamed = await _http.send(request);
      response = await http.Response.fromStream(
        streamed,
      ).timeout(_transferDeadline);
    } on TimeoutException {
      throw const TransportException('POST /attachments got no answer');
    } catch (e) {
      throw TransportException('POST /attachments failed: $e');
    }
    if (response.statusCode == 401 && !isRetry && session.tokens != null) {
      await refresh();
      return uploadAttachmentStream(
        open,
        length: length,
        filename: filename,
        onProgress: onProgress,
        isRetry: true,
      );
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return Attachment.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw _errorFor(response);
  }

  /// Fetches an attachment's raw bytes. Requires viewing a channel that has a
  /// live message attaching it, checked across every channel that does,
  /// since content addressing means more than one message can share the
  /// same bytes.
  Future<FetchedBytes> fetchAttachment(String attachmentId) =>
      _fetchBytes('/attachments/$attachmentId');

  /// The same endpoint [fetchAttachment] reads, for a caller that streams the
  /// bytes itself rather than loading them into memory - a native video
  /// player, which can attach `session.tokens?.accessToken` as its own
  /// bearer header and let the player issue range requests directly. Carries
  /// no token itself: this is only the address.
  Uri attachmentUrl(String attachmentId) =>
      _requestUri('/attachments/$attachmentId', null);
}
