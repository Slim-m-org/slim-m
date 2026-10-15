// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Files above this go through upload sessions when the server offers them.
const kUploadSessionThreshold = 32 * 1024 * 1024;

/// The size of one part; the server's own ceiling is applied on top.
const kUploadPartBytes = 16 * 1024 * 1024;

const _uploadSessionCapability = 'upload_sessions';
const _partRetries = 5;
const _partSendDeadline = Duration(minutes: 5);

/// Whether a file of [length] bytes should be sent in sessions: only a server
/// that advertises them, and only past the size where one request is risky.
bool usesUploadSessions({
  required int length,
  required List<String>? capabilities,
  int threshold = kUploadSessionThreshold,
}) =>
    length > threshold &&
    (capabilities?.contains(_uploadSessionCapability) ?? false);

Duration _defaultBackoff(int attempt) =>
    Duration(milliseconds: 500 * (1 << (attempt - 1)));

/// Errors a part can recover from by asking the server where it got to.
bool _isResumable(ApiException e) => switch (e) {
      TransportException() ||
      ConflictException() ||
      RateLimitedException() ||
      UnavailableException() =>
        true,
      ServerException(:final statusCode) =>
        statusCode >= 500 && statusCode != 507,
      _ => false,
    };

/// Large uploads in resumable parts, for a path that cannot carry them whole.
extension SlimmApiUploadSessions on SlimmApi {
  /// Uploads [source] in one request, or in resumable parts when
  /// [usesUploadSessions] says [capabilities] and [length] call for it.
  ///
  /// A failed part is retried up to five times without progress, after asking
  /// the server how much it holds and carrying on from there. Cancelling
  /// through [cancel], or giving up, discards the session. [sessionThreshold],
  /// [partBytes] and [backoff] are there for tests to shrink.
  Future<Attachment> uploadAttachmentAuto(
    UploadSource source, {
    required int length,
    required List<String>? capabilities,
    String? filename,
    void Function(int sent)? onProgress,
    UploadCancelToken? cancel,
    int sessionThreshold = kUploadSessionThreshold,
    int partBytes = kUploadPartBytes,
    Duration Function(int attempt) backoff = _defaultBackoff,
  }) {
    final sessions = usesUploadSessions(
      length: length,
      capabilities: capabilities,
      threshold: sessionThreshold,
    );
    if (!sessions) {
      return uploadAttachmentStream(
        source.open,
        length: length,
        filename: filename,
        onProgress: onProgress,
      );
    }
    return _uploadResumable(
      source,
      length: length,
      filename: filename,
      onProgress: onProgress,
      cancel: cancel,
      backoff: backoff,
      partBytes: partBytes,
    );
  }

  Future<Attachment> _uploadResumable(
    UploadSource source, {
    required int length,
    String? filename,
    void Function(int sent)? onProgress,
    UploadCancelToken? cancel,
    required Duration Function(int attempt) backoff,
    required int partBytes,
  }) async {
    final session = await _createUploadSession(filename, length);
    try {
      return await _drive(
        session,
        source,
        length: length,
        onProgress: onProgress,
        cancel: cancel,
        backoff: backoff,
        partBytes: partBytes,
      );
    } catch (_) {
      unawaited(_discardUploadSession(session.id).catchError((Object _) {}));
      rethrow;
    } finally {
      await source.close();
    }
  }

  Future<Attachment> _drive(
    UploadSession session,
    UploadSource source, {
    required int length,
    required void Function(int sent)? onProgress,
    required UploadCancelToken? cancel,
    required Duration Function(int attempt) backoff,
    required int partBytes,
  }) async {
    var offset = session.offset;
    var failures = 0;
    while (true) {
      cancel?.throwIfCancelled();
      try {
        if (offset >= length) return await _completeUploadSession(session.id);
        final take = math.min(
          math.min(partBytes, session.partMaxBytes),
          length - offset,
        );
        final from = offset;
        final after = await _appendUploadPart(
          session.id,
          from,
          () => source.part(from, take, cancel: cancel),
          take,
          (sent) => onProgress?.call(from + sent),
        );
        if (after.offset <= from) {
          throw const TransportException('the server did not take the part');
        }
        offset = after.offset;
        failures = 0;
      } on ApiException catch (e) {
        cancel?.throwIfCancelled();
        if (!_isResumable(e)) rethrow;
        await source.close();
        final held = await _heldBytes(session.id);
        if (held != null && held > offset) failures = 0;
        if (held != null) offset = held;
        if (++failures > _partRetries) rethrow;
        await Future<void>.delayed(
          e is RateLimitedException && e.retryAfter != null
              ? e.retryAfter!
              : backoff(failures),
        );
      }
    }
  }

  /// Where the server's copy ends, or null when it cannot be asked right now.
  Future<int?> _heldBytes(String id) async {
    try {
      return (await _getUploadSession(id)).offset;
    } on ApiException {
      return null;
    }
  }

  Future<UploadSession> _createUploadSession(String? filename, int size) async {
    final json = await _send(
      'POST',
      '/attachments/uploads',
      body: {if (filename != null) 'filename': filename, 'size': size},
    );
    return _decodeShape(
        json, 'POST /attachments/uploads', UploadSession.fromJson);
  }

  Future<UploadSession> _getUploadSession(String id) async {
    final json = await _send('GET', '/attachments/uploads/$id');
    return _decodeShape(
      json,
      'GET /attachments/uploads/$id',
      UploadSession.fromJson,
    );
  }

  Future<UploadSession> _appendUploadPart(
    String id,
    int offset,
    Stream<List<int>> Function() open,
    int length,
    void Function(int sent) onProgress,
  ) async {
    final response = await _sendStreamed(
      'PUT',
      '/attachments/uploads/$id',
      open: open,
      length: length,
      query: {'offset': '$offset'},
      onProgress: onProgress,
      sendDeadline: _partSendDeadline,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _errorFor(response);
    }
    return _decodeShape(
      jsonDecode(response.body),
      'PUT /attachments/uploads/$id',
      UploadSession.fromJson,
    );
  }

  Future<void> _discardUploadSession(String id) =>
      _send('DELETE', '/attachments/uploads/$id', expectNoContent: true);

  Future<Attachment> _completeUploadSession(String id) async {
    final json = await _send('POST', '/attachments/uploads/$id/complete');
    return _decodeShape(
      json,
      'POST /attachments/uploads/$id/complete',
      Attachment.fromJson,
    );
  }
}
