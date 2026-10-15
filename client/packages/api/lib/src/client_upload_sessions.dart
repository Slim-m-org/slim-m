// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Files above this go through upload sessions when the server offers them.
const kUploadSessionThreshold = 32 * 1024 * 1024;

/// The size of one part; the server's own ceiling is applied on top.
const kUploadPartBytes = 16 * 1024 * 1024;

const _uploadSessionCapability = 'upload_sessions';
const _partSendDeadline = Duration(minutes: 5);

/// How long an upload keeps retrying without moving forward. Long enough to
/// ride out a redeploy, a router restart or a laptop changing networks.
const kUploadStallLimit = Duration(minutes: 10);

/// Whether a file of [length] bytes should be sent in sessions: only a server
/// that advertises them, and only past the size where one request is risky.
bool usesUploadSessions({
  required int length,
  required List<String>? capabilities,
  int threshold = kUploadSessionThreshold,
}) =>
    length > threshold &&
    (capabilities?.contains(_uploadSessionCapability) ?? false);

Duration _defaultBackoff(int attempt) => Duration(
      milliseconds: math.min(500 * (1 << math.min(attempt - 1, 6)), 30000),
    );

enum _PartFailure { transient, gone, fatal }

_PartFailure _classify(ApiException e) => switch (e) {
      // A proxy answers 404 while the server behind it restarts.
      NotFoundException(:final unexplained) =>
        unexplained ? _PartFailure.transient : _PartFailure.gone,
      TransportException() ||
      ConflictException() ||
      RateLimitedException() ||
      UnavailableException() =>
        _PartFailure.transient,
      ServerException(:final statusCode) =>
        statusCode >= 500 && statusCode != 507
            ? _PartFailure.transient
            : _PartFailure.fatal,
      _ => _PartFailure.fatal,
    };

/// Large uploads in resumable parts, for a path that cannot carry them whole.
extension SlimmApiUploadSessions on SlimmApi {
  /// Uploads [source] in one request, or in resumable parts when the server
  /// offers them and [length] calls for it. [capabilities] null means the
  /// caller could not learn them, so they are asked for here, patiently.
  ///
  /// A failed part is retried, after asking the server how much it holds,
  /// until [stallLimit] passes with no progress; [onRetrying] reports when a
  /// retry starts and when progress resumes. Giving up on a failure that could
  /// still recover keeps the session under [resumeKey], so a later call with
  /// the same key carries on from where it stopped. Cancelling through
  /// [cancel], or a failure that cannot recover, discards it.
  /// [sessionThreshold], [partBytes], [backoff] and [stallLimit] are there for
  /// tests to shrink.
  Future<Attachment> uploadAttachmentAuto(
    UploadSource source, {
    required int length,
    required List<String>? capabilities,
    String? filename,
    void Function(int sent)? onProgress,
    void Function(bool retrying)? onRetrying,
    UploadCancelToken? cancel,
    String? resumeKey,
    int sessionThreshold = kUploadSessionThreshold,
    int partBytes = kUploadPartBytes,
    Duration Function(int attempt) backoff = _defaultBackoff,
    Duration stallLimit = kUploadStallLimit,
  }) async {
    final known = length > sessionThreshold
        ? capabilities ??
            await _patiently(
              () async => (await version()).capabilities,
              cancel: cancel,
              backoff: backoff,
              stallLimit: stallLimit,
            )
        : capabilities;
    final sessions = usesUploadSessions(
      length: length,
      capabilities: known,
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
      onRetrying: onRetrying,
      cancel: cancel,
      resumeKey: resumeKey,
      backoff: backoff,
      stallLimit: stallLimit,
      partBytes: partBytes,
    );
  }

  /// Discards the session kept under [resumeKey], for a file removed rather
  /// than retried, so it does not hold server disk until the daily sweep.
  void abandonUpload(String resumeKey) {
    final id = _resumableUploads.remove(resumeKey);
    if (id == null) return;
    unawaited(_discardUploadSession(id).catchError((Object _) {}));
  }

  /// Runs [action], retrying a failure that could recover until [stallLimit].
  Future<T> _patiently<T>(
    Future<T> Function() action, {
    required UploadCancelToken? cancel,
    required Duration Function(int attempt) backoff,
    required Duration stallLimit,
  }) async {
    final started = DateTime.now();
    var attempt = 0;
    while (true) {
      cancel?.throwIfCancelled();
      try {
        return await action();
      } on ApiException catch (e) {
        if (_classify(e) != _PartFailure.transient ||
            DateTime.now().difference(started) > stallLimit) {
          rethrow;
        }
        await Future<void>.delayed(backoff(++attempt));
      }
    }
  }

  Future<Attachment> _uploadResumable(
    UploadSource source, {
    required int length,
    String? filename,
    void Function(int sent)? onProgress,
    void Function(bool retrying)? onRetrying,
    UploadCancelToken? cancel,
    String? resumeKey,
    required Duration Function(int attempt) backoff,
    required Duration stallLimit,
    required int partBytes,
  }) async {
    Future<UploadSession> create() => _patiently(
          () => _createUploadSession(filename, length),
          cancel: cancel,
          backoff: backoff,
          stallLimit: stallLimit,
        );
    final kept = resumeKey == null ? null : _resumableUploads.remove(resumeKey);
    var session = await _resumeOrCreate(kept, length, create);
    var restarted = false;
    try {
      while (true) {
        try {
          return await _drive(
            session,
            source,
            length: length,
            onProgress: onProgress,
            onRetrying: onRetrying,
            cancel: cancel,
            backoff: backoff,
            stallLimit: stallLimit,
            partBytes: partBytes,
          );
        } on ApiException catch (e) {
          // The server lost the session (swept, or its disk was reset): start over once.
          if (_classify(e) != _PartFailure.gone || restarted) rethrow;
          restarted = true;
          await source.close();
          session = await create();
        }
      }
    } on ApiException catch (e) {
      if (resumeKey != null && _classify(e) == _PartFailure.transient) {
        _resumableUploads[resumeKey] = session.id;
      } else {
        unawaited(_discardUploadSession(session.id).catchError((Object _) {}));
      }
      rethrow;
    } catch (_) {
      unawaited(_discardUploadSession(session.id).catchError((Object _) {}));
      rethrow;
    } finally {
      await source.close();
    }
  }

  /// The kept session when the server still holds it for a file this size,
  /// else a fresh one.
  Future<UploadSession> _resumeOrCreate(
    String? kept,
    int length,
    Future<UploadSession> Function() create,
  ) async {
    if (kept != null) {
      try {
        final held = await _getUploadSession(kept);
        if (held.size == length) return held;
      } on ApiException {
        // Gone or unreachable: a fresh session is the honest start.
      }
      unawaited(_discardUploadSession(kept).catchError((Object _) {}));
    }
    return create();
  }

  Future<Attachment> _drive(
    UploadSession session,
    UploadSource source, {
    required int length,
    required void Function(int sent)? onProgress,
    required void Function(bool retrying)? onRetrying,
    required UploadCancelToken? cancel,
    required Duration Function(int attempt) backoff,
    required Duration stallLimit,
    required int partBytes,
  }) async {
    var offset = session.offset;
    var failures = 0;
    DateTime? stalledSince;
    void progressed() {
      if (stalledSince != null) onRetrying?.call(false);
      failures = 0;
      stalledSince = null;
    }

    while (true) {
      cancel?.throwIfCancelled();
      try {
        if (offset >= length) {
          final done = await _completeUploadSession(session.id);
          progressed();
          return done;
        }
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
        progressed();
      } on ApiException catch (e) {
        cancel?.throwIfCancelled();
        if (_classify(e) != _PartFailure.transient) rethrow;
        final now = DateTime.now();
        if (stalledSince == null) onRetrying?.call(true);
        stalledSince ??= now;
        await source.close();
        final held = await _heldBytes(session.id);
        if (held != null && held > offset) {
          offset = held;
          stalledSince = now;
          failures = 0;
        } else if (held != null) {
          offset = held;
        }
        if (now.difference(stalledSince!) > stallLimit) rethrow;
        failures++;
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
