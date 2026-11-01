// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'exceptions.dart';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

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
    final json = await send(
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
    String? channelId,
    void Function(int sent)? onProgress,
  }) async {
    final response = await sendStreamed(
      'POST',
      '/attachments',
      open: open,
      length: length,
      query: {
        if (filename != null) 'filename': filename,
        if (channelId != null) 'channel_id': channelId,
      },
      onProgress: onProgress,
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return Attachment.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw errorFor(response);
  }

  /// Sends a raw body read from [open] and answers the response unmapped, so
  /// the caller decides what a status means. Replays once after a 401.
  ///
  /// [sendDeadline] bounds the send itself, which a plain upload leaves open
  /// but a part of a resumable one cannot: a stalled part has to fail so the
  /// uploader can resume from the server's offset.
  Future<http.Response> sendStreamed(
    String method,
    String path, {
    required Stream<List<int>> Function() open,
    required int length,
    Map<String, String>? query,
    void Function(int sent)? onProgress,
    Duration? sendDeadline,
    bool isRetry = false,
  }) async {
    final token = session.tokens?.accessToken;
    if (token == null) throw const UnauthorizedException('not signed in');
    final request = http.StreamedRequest(method, requestUri(path, query))
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
      var sending = link.client.send(request);
      if (sendDeadline != null) sending = sending.timeout(sendDeadline);
      response = await http.Response.fromStream(
        await sending,
      ).timeout(transferDeadline);
    } on TimeoutException {
      throw TransportException('$method $path got no answer');
    } catch (e) {
      throw TransportException('$method $path failed: $e');
    }
    if (response.statusCode == 401 && !isRetry && session.tokens != null) {
      await refresh();
      return sendStreamed(
        method,
        path,
        open: open,
        length: length,
        query: query,
        onProgress: onProgress,
        sendDeadline: sendDeadline,
        isRetry: true,
      );
    }
    return response;
  }

  /// Fetches an attachment's raw bytes. Requires viewing a channel that has a
  /// live message attaching it, checked across every channel that does,
  /// since content addressing means more than one message can share the
  /// same bytes.
  ///
  /// With [previewWidth] the server answers a smaller preview of a still image
  /// or the first frame of a gif where it can, and the original otherwise;
  /// read [FetchedBytes.contentType] rather than assuming which one came back.
  /// [firstFrame] also asks for the first frame of an animated webp or png.
  Future<FetchedBytes> fetchAttachment(
    String attachmentId, {
    int? previewWidth,
    bool firstFrame = false,
  }) =>
      fetchBytes(
        '/attachments/$attachmentId',
        query: previewWidth == null
            ? null
            : {'w': '$previewWidth', if (firstFrame) 'still': 'true'},
      );

  /// Opens an attachment as a stream, with no deadline on the body itself: a
  /// multi-gigabyte file legitimately takes longer than any whole-transfer
  /// deadline. Only the wait for the response headers is bounded here; the
  /// caller bounds the gap between chunks.
  ///
  /// With [original] the file as uploaded, where the space kept it.
  Future<AttachmentDownload> openAttachmentDownload(
    String attachmentId, {
    bool original = false,
  }) =>
      openDownload(
        '/attachments/$attachmentId',
        original ? {'original': 'true'} : null,
      );

  /// Streams a GET with no body deadline and one token refresh on a 401.
  Future<AttachmentDownload> openDownload(
    String path,
    Map<String, String>? query, {
    bool isRetry = false,
  }) async {
    final token = session.tokens?.accessToken;
    if (token == null) throw const UnauthorizedException('not signed in');
    final request = http.Request('GET', requestUri(path, query))
      ..headers['authorization'] = 'Bearer $token';
    final http.StreamedResponse response;
    try {
      response = await link.client.send(request).timeout(requestDeadline);
    } on TimeoutException {
      throw TransportException('GET $path got no answer');
    } catch (e) {
      throw TransportException('GET $path failed: $e');
    }
    if (response.statusCode == 401 && !isRetry && session.tokens != null) {
      await response.stream.drain<void>();
      await refresh();
      return openDownload(path, query, isRetry: true);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw errorFor(await http.Response.fromStream(response));
    }
    return AttachmentDownload(
      body: response.stream,
      contentType:
          response.headers['content-type'] ?? 'application/octet-stream',
      contentLength: response.contentLength,
    );
  }

  /// The same endpoint [fetchAttachment] reads, for a caller that streams the
  /// bytes itself rather than loading them into memory - a native video
  /// player, which can attach `session.tokens?.accessToken` as its own
  /// bearer header and let the player issue range requests directly. Carries
  /// no token itself: this is only the address.
  Uri attachmentUrl(String attachmentId) =>
      requestUri('/attachments/$attachmentId', null);
}
