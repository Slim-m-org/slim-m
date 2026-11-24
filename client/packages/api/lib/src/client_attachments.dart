// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'package:http/http.dart' as http;
import 'exceptions.dart';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';
import 'upload_guard.dart';
import 'upload_send.dart';
import 'upload_source.dart';

/// How long a plain upload may go without a byte moving before it fails.
const kUploadStallDeadline = Duration(seconds: 60);

/// [body] that stops at once when [guard] gave up and counts each chunk as movement.
Stream<List<int>> _watched(Stream<List<int>> body, UploadGuard guard) async* {
  await for (final chunk in body) {
    if (guard.stopped) return;
    guard.touch();
    yield chunk;
  }
}

/// Attachments: upload bytes once, reference the returned id in
/// [SlimmApi.sendMessage], fetch them back. The `attachments` tag.
extension SlimmApiAttachments on SlimmApi {
  /// Uploads an attachment's raw [bytes]. Idempotent by content: uploading
  /// bytes that already exist returns the existing id rather than storing a
  /// second copy. An id never referenced by a message is reclaimed
  /// automatically after a day, so upload right before sending rather than
  /// far ahead of it.
  ///
  /// With [voice] the upload is marked as a voice message, and the server
  /// returns it with its length and waveform.
  Future<Attachment> uploadAttachment(
    List<int> bytes, {
    String? filename,
    String? channelId,
    VoiceInfo? voice,
  }) async {
    final json = await send(
      'POST',
      '/attachments',
      bytes: bytes,
      query: {
        if (filename != null) 'filename': filename,
        if (channelId != null) 'channel_id': channelId,
        if (voice != null) ...{
          'voice': 'true',
          'duration_ms': '${voice.duration.inMilliseconds}',
          'waveform': voice.waveform
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join(),
        },
      },
    );
    return Attachment.fromJson(json as Map<String, dynamic>);
  }

  /// Uploads [length] bytes read from [open] without holding them in memory,
  /// calling [onProgress] with the running byte count as they are consumed.
  ///
  /// [open] is a factory, not a stream: the one-shot refresh-and-replay after
  /// a 401 has to read the body again from the start.
  ///
  /// The upload fails with a [TransportException] once [stallDeadline] passes
  /// with no byte moving, and stops with [UploadCancelled] when [cancel] trips.
  Future<Attachment> uploadAttachmentStream(
    Stream<List<int>> Function() open, {
    required int length,
    String? filename,
    String? channelId,
    void Function(int sent)? onProgress,
    UploadCancelToken? cancel,
    Duration stallDeadline = kUploadStallDeadline,
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
      cancel: cancel,
      stallDeadline: stallDeadline,
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decodeShape(
        decodeJsonReply(response, 'POST /attachments'),
        'POST /attachments',
        Attachment.fromJson,
      );
    }
    throw errorFor(response);
  }

  /// Sends a raw body read from [open] and answers the response unmapped, so
  /// the caller decides what a status means. Replays once after a 401.
  ///
  /// [sendDeadline] bounds the whole send and [stallDeadline] the gap between
  /// moving bytes: a stalled part has to fail so the uploader can resume from
  /// the server's offset. Either one, and [cancel], also abort the request.
  Future<http.Response> sendStreamed(
    String method,
    String path, {
    required Stream<List<int>> Function() open,
    required int length,
    Map<String, String>? query,
    void Function(int sent)? onProgress,
    Duration? sendDeadline,
    Duration? stallDeadline,
    UploadCancelToken? cancel,
    bool isRetry = false,
  }) async {
    cancel?.throwIfCancelled();
    await awaitTrust();
    final token = session.tokens?.accessToken;
    if (token == null) throw const UnauthorizedException('not signed in');
    final guard = UploadGuard(
      stall: stallDeadline,
      total: sendDeadline,
      cancel: cancel,
    );
    final request = http.AbortableStreamedRequest(
      method,
      requestUri(path, query),
      abortTrigger: guard.abortTrigger,
    )
      ..contentLength = length
      ..headers['content-type'] = 'application/octet-stream'
      ..headers['authorization'] = 'Bearer $token';
    final http.Response response;
    try {
      final sending = sendUpload(
        link.client,
        request,
        _watched(open(), guard),
        abortTrigger: guard.abortTrigger,
        onProgress: (sent) {
          guard.touch();
          if (sent >= length) guard.rearm(transferDeadline);
          onProgress?.call(sent);
        },
      );
      final streamed = await guard.guard(sending);
      guard.dispose();
      response = await http.Response.fromStream(
        streamed,
      ).timeout(transferDeadline);
    } on UploadCancelled {
      rethrow;
    } on TimeoutException {
      throw TransportException('$method $path got no answer');
    } catch (e) {
      throw TransportException('$method $path failed: $e');
    } finally {
      guard.dispose();
    }
    if (response.statusCode == 401 && !isRetry && session.tokens != null) {
      await refreshUnlessRotated(token);
      return sendStreamed(
        method,
        path,
        open: open,
        length: length,
        query: query,
        onProgress: onProgress,
        sendDeadline: sendDeadline,
        stallDeadline: stallDeadline,
        cancel: cancel,
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
    await awaitTrust();
    final token = session.tokens?.accessToken;
    if (token == null) throw const UnauthorizedException('not signed in');
    final uri = requestUri(path, query);
    Future<http.StreamedResponse> attempt() async {
      final request = http.Request('GET', uri)
        ..headers['authorization'] = 'Bearer $token';
      try {
        return await link.client.send(request).timeout(requestDeadline);
      } on TimeoutException {
        throw TransportException('GET $path got no answer');
      } on http.ClientException catch (e) {
        throw ConnectionDroppedException('GET $path failed: $e');
      } catch (e) {
        throw TransportException('GET $path failed: $e');
      }
    }

    final response = await replayingDroppedSocket('GET', attempt);
    if (response.statusCode == 401 && !isRetry && session.tokens != null) {
      await response.stream.drain<void>();
      await refreshUnlessRotated(token);
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
