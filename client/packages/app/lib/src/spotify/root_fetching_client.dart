// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An HTTP client for Windows that survives a root certificate Windows trusts
/// but has not downloaded yet.
///
/// Windows ships a few dozen roots and fetches the rest the first time its
/// own TLS stack meets one. Dart's TLS only reads the roots already stored,
/// so on a machine that never met Spotify's root through Windows (Edge uses
/// its own root store, so signing in there does not count), the token
/// exchange failed with CERTIFICATE_VERIFY_FAILED. This client lets Windows
/// fetch the root once, then retries with a context that reads the store again.
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Opens [host] through Windows' own TLS stack, which downloads a missing root.
typedef FetchRoots = Future<void> Function(String host);

/// Builds the inner client; a null context means the process default.
typedef BuildClient = http.Client Function(SecurityContext? context);

http.Client _ioClient(SecurityContext? context) =>
    context == null ? http.Client() : IOClient(HttpClient(context: context));

class RootFetchingClient extends http.BaseClient {
  RootFetchingClient({required FetchRoots fetchRoots, BuildClient? build})
    : _fetchRoots = fetchRoots,
      _build = build ?? _ioClient,
      _inner = (build ?? _ioClient)(null);

  final FetchRoots _fetchRoots;
  final BuildClient _build;
  http.Client _inner;

  /// Replaced clients, closed with this one: another request may still use them.
  final _retired = <http.Client>[];

  /// Hosts already given a fetch, so a root Windows will not supply is not
  /// asked for again on every request.
  final _fetched = <String>{};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final replay = request is http.Request ? _copy(request) : null;
    try {
      return await _inner.send(request);
    } on HandshakeException catch (error) {
      final host = request.url.host;
      if (replay == null || !_unknownIssuer(error) || !_fetched.add(host)) {
        rethrow;
      }
      await _fetchRoots(host);
      _retired.add(_inner);
      _inner = _build(SecurityContext(withTrustedRoots: true));
      return _inner.send(replay);
    }
  }

  @override
  void close() {
    _inner.close();
    for (final client in _retired) {
      client.close();
    }
  }

  static bool _unknownIssuer(HandshakeException error) =>
      '$error'.contains('CERTIFICATE_VERIFY_FAILED');

  static http.Request _copy(http.Request request) =>
      http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection;
}
