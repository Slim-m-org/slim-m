// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// The only code in this package that speaks HTTP.
///
/// Every typed method in every other part of [SlimmApi] is a wrapper over
/// [SlimmApi._send] or [SlimmApi._fetchBytes], which is why the one-shot
/// refresh-and-replay, the status-to-exception mapping, and turning a path
/// built from a wire-supplied value into a safe request [Uri] are all
/// written once, here, rather than per endpoint.
/// How long an ordinary request may take before the caller stops waiting.
///
/// Above the server's own 30-second request timeout on purpose, so a server
/// that is going to answer gets to, and this only fires when nothing is coming
/// back at all. Without it there is no deadline anywhere: `http.Client` sets
/// none on either backend, so a server that accepts a connection and never
/// answers hangs its caller for the life of the process. The reachable case is
/// a mobile network transition, and the visible one is a spinner whose
/// `finally` never runs.
const _requestDeadline = Duration(seconds: 45);

/// The same, for a request whose body is the point: an upload, or an
/// attachment or avatar fetch.
///
/// Longer because ten megabytes over a poor link legitimately takes minutes,
/// and a deadline that kills a transfer which is making progress is worse than
/// the hang it replaces.
const _transferDeadline = Duration(minutes: 3);

extension SlimmApiTransport on SlimmApi {
  Future<Object?> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    List<int>? bytes,
    Map<String, String>? query,
    bool authenticated = true,
    bool expectNoContent = false,
    bool isRetry = false,
    void Function(int status)? onStatus,
  }) async {
    final uri = _requestUri(path, query);
    final request = http.Request(method, uri);
    if (bytes != null) {
      // An upload (an attachment or an avatar): the request body is the raw
      // bytes, never JSON, though the response below still is.
      request.headers['content-type'] = 'application/octet-stream';
      request.bodyBytes = bytes;
    } else if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (authenticated) {
      final token = session.tokens?.accessToken;
      if (token == null) {
        throw const UnauthorizedException('not signed in');
      }
      request.headers['authorization'] = 'Bearer $token';
    }

    final response = await _perform(
      request,
      '$method $path',
      deadline: bytes == null ? _requestDeadline : _transferDeadline,
    );

    // One automatic rotation, then replay. Only for authenticated calls, and
    // never twice for the same request.
    if (response.statusCode == 401 &&
        authenticated &&
        !isRetry &&
        session.tokens != null) {
      await refresh();
      return _send(
        method,
        path,
        body: body,
        bytes: bytes,
        query: query,
        authenticated: authenticated,
        expectNoContent: expectNoContent,
        onStatus: onStatus,
        isRetry: true,
      );
    }

    // Sign-in is the one call with two *successful* outcomes; see `SlimmApiAuth.login`.
    onStatus?.call(response.statusCode);
    if (response.statusCode == 204 ||
        (expectNoContent && response.statusCode < 300)) {
      return null;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      try {
        return jsonDecode(response.body) as Object;
      } catch (e) {
        throw TransportException(
          'could not decode the reply to $method $path: $e',
        );
      }
    }
    throw _errorFor(response);
  }

  /// Like [_send], for an authenticated GET whose response is raw bytes
  /// rather than JSON (an attachment or an avatar fetch): the same one-shot
  /// refresh-and-retry and error mapping, without a JSON decode that would
  /// only fail on a body that was never JSON to begin with.
  Future<FetchedBytes> _fetchBytes(String path, {bool isRetry = false}) async {
    final request = http.Request('GET', _requestUri(path, null));
    final token = session.tokens?.accessToken;
    if (token == null) {
      throw const UnauthorizedException('not signed in');
    }
    request.headers['authorization'] = 'Bearer $token';

    final response = await _perform(
      request,
      'GET $path',
      deadline: _transferDeadline,
    );

    if (response.statusCode == 401 && !isRetry && session.tokens != null) {
      await refresh();
      return _fetchBytes(path, isRetry: true);
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return FetchedBytes(
        bytes: response.bodyBytes,
        contentType:
            response.headers['content-type'] ?? 'application/octet-stream',
      );
    }
    throw _errorFor(response);
  }

  /// Sends [request] and reads its whole response under one [deadline],
  /// mapping every failure to a [TransportException] so a caller's existing
  /// `on ApiException` reaches it.
  ///
  /// The one place both entry points share, which is the point: a deadline
  /// added to [_send] alone would have left the three byte-fetching routes
  /// unbounded with nothing failing to say so, and `_fetchBytes` had been a
  /// hand-copy of this since it was written.
  ///
  /// The deadline covers the round trip rather than each half, so a slow
  /// response cannot be granted twice the budget by arriving in two stages.
  /// It is composed with `.then` and never by wrapping the send in
  /// `Future(() async { ... })`: that wrapper defers even *starting* the
  /// request by an event-loop turn, which is invisible against a real clock
  /// and moves every response a pump later under a widget test's fake one. It
  /// broke a dozen unrelated tests, only some of the time, and the failure
  /// names nothing relevant - the harness crashes with "Cannot add event while
  /// adding stream" and the job never finishes.
  /// What it does not do is cancel the request: `Future.timeout` abandons the
  /// wait, and the socket is left to the client's own cleanup. That is the
  /// difference between a caller that recovers and one that does not, which is
  /// what this is for.
  Future<http.Response> _perform(
    http.Request request,
    String label, {
    required Duration deadline,
  }) async {
    try {
      // Chained, never `Future(() async { ... })`; see the note on this method.
      return await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(deadline);
    } on TimeoutException {
      throw TransportException(
        '$label got no answer within ${deadline.inSeconds} seconds',
      );
    } catch (e) {
      throw TransportException('$label failed: $e');
    }
  }

  /// Turns an already-interpolated [path] (e.g.
  /// `/messages/$messageId/reactions/$emoji`) into a request [Uri] without
  /// letting a wire-supplied value decide which resource it reaches.
  ///
  /// [Uri.replace]'s `path` parameter resolves `.`/`..` segments per RFC
  /// 3986, including a percent-encoded pair (`%2e%2e` reads the same as
  /// `..`), so a value this file did not choose - an emoji string, say -
  /// can walk the request off the endpoint that built it. Splitting on the
  /// literal `/` this file wrote and handing the pieces to `pathSegments`
  /// closes that for every segment: each piece is then one opaque value,
  /// so an embedded `/`, `%`, or non-ASCII byte in it can never introduce a
  /// new separator. `pathSegments` still resolves a piece that is *exactly*
  /// `.` or `..` the same way `path` does, so [_withoutDotSegment] escapes
  /// only those two literal values; every other segment renders exactly as
  /// `pathSegments` already renders it today.
  Uri _requestUri(String path, Map<String, String>? query) {
    final parts = path.split('/');
    final segments =
        (parts.isNotEmpty && parts.first.isEmpty ? parts.skip(1) : parts)
            .map(_withoutDotSegment)
            .toList(growable: false);
    return baseUrl.replace(pathSegments: segments, queryParameters: query);
  }

  ApiException _errorFor(http.Response response) {
    var reason = 'request failed';
    int? missingPermissions;
    Duration? bodyRetryAfter;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        reason = decoded['error'] as String;
      }
      if (decoded is Map<String, dynamic> &&
          decoded['missing_permissions'] is int) {
        missingPermissions = decoded['missing_permissions'] as int;
      }
      if (decoded is Map<String, dynamic> &&
          decoded['retry_after_seconds'] is int &&
          (decoded['retry_after_seconds'] as int) >= 0) {
        bodyRetryAfter = Duration(
          seconds: decoded['retry_after_seconds'] as int,
        );
      }
    } catch (_) {
      // A non-JSON body is not itself an error worth surfacing; the status is.
    }
    return switch (response.statusCode) {
      400 => BadRequestException(reason),
      401 => UnauthorizedException(reason),
      403 => ForbiddenException(
          reason,
          missingPermissions: missingPermissions,
        ),
      404 => NotFoundException(reason),
      409 => ConflictException(reason),
      429 => RateLimitedException(
          reason,
          retryAfter: _retryAfter(response) ?? bodyRetryAfter,
        ),
      501 => NotConfiguredException(reason),
      503 => UnavailableException(reason),
      _ => ServerException(reason, response.statusCode),
    };
  }
}

/// `.` and `..` are the only two path segments [Uri] resolves away per RFC
/// 3986, even when a segment arrives through `pathSegments` rather than a
/// raw `path` string; escaping just their dots leaves every other segment
/// exactly as `pathSegments` already renders it.
String _withoutDotSegment(String segment) => (segment == '.' || segment == '..')
    ? segment.replaceAll('.', '%2E')
    : segment;

/// The delay a `Retry-After` header names, or null if there is none or it
/// does not parse.
///
/// Only the delta-seconds form (RFC 9110 10.2.3) is read. A server older than
/// the rate-limit hint sends it on a slow-mode 429 only, so a caller with no
/// value here falls back to its own backoff.
/// The alternative HTTP-date form is deliberately not parsed: nothing this
/// server or a caller of it would ever send needs it.
Duration? _retryAfter(http.Response response) {
  final header = response.headers['retry-after'];
  if (header == null) return null;
  final seconds = int.tryParse(header.trim());
  if (seconds == null || seconds < 0) return null;
  return Duration(seconds: seconds);
}

/// [fromJson] over [json], or a [TransportException] when the reply is not the
/// object shape [what] promises, so no TypeError escapes the ApiException catches.
T _decodeShape<T>(
  Object? json,
  String what,
  T Function(Map<String, dynamic>) fromJson,
) {
  try {
    return fromJson(json as Map<String, dynamic>);
  } on TypeError catch (e) {
    throw TransportException('unexpected reply to $what: $e');
  }
}
