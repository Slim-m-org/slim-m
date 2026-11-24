// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every dart:io HTTP and WebSocket connection survives a root certificate
/// the OS trusts but has not stored yet (decision 0056, Windows addendum).
///
/// Windows ships a few dozen roots and downloads the rest the first time its
/// own TLS stack needs one. Dart's TLS reads only what is already stored, so
/// a server behind a less common CA failed with CERTIFICATE_VERIFY_FAILED on
/// a fresh machine. [RootFetchingHttpOverrides] wraps each client built with
/// the default trust: when opening a connection fails that way, it asks
/// [AddTrustedRoots] to let the OS fetch the root and add the stored roots to
/// [SecurityContext.defaultContext], then opens the connection once more.
/// The default context is shared, so connections secured by hand with it
/// (the direct route's own socket factory) gain the root as well.
library;

import 'dart:async';
import 'dart:io';

/// Lets the OS fetch what [url]'s host needs and adds its stored roots to the
/// default context. True when it added any, so a retry can succeed.
typedef AddTrustedRoots = Future<bool> Function(Uri url);

class RootFetchingHttpOverrides extends HttpOverrides {
  RootFetchingHttpOverrides(this._addRoots);

  final AddTrustedRoots _addRoots;

  /// One attempt per host and port, shared by every client; a failed one is dropped so the next connect asks again.
  final _attempts = <String, Future<bool>>{};

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = super.createHttpClient(context);
    // A caller's own context is its own trust decision; only the default is widened.
    return context == null ? RootFetchingHttpClient(inner, this) : inner;
  }

  Future<bool> _rootsAddedFor(Uri url) {
    final key = '${url.host}:${url.port}';
    return _attempts.putIfAbsent(key, () => _attempt(key, url));
  }

  Future<bool> _attempt(String key, Uri url) async {
    var added = false;
    try {
      added = await _addRoots(url);
    } finally {
      if (!added) _attempts.removeWhere((k, _) => k == key);
    }
    return added;
  }
}

/// Delegates to the dart:io client and retries [openUrl] once after a missing
/// root; a connection that fails later, mid-request, is not retried.
class RootFetchingHttpClient implements HttpClient {
  RootFetchingHttpClient(this._inner, this._owner);

  final HttpClient _inner;
  final RootFetchingHttpOverrides _owner;

  static bool isMissingRoot(Object error) =>
      error is HandshakeException &&
      '$error'.contains('CERTIFICATE_VERIFY_FAILED');

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    try {
      return await _inner.openUrl(method, url);
    } on HandshakeException catch (error) {
      if (!isMissingRoot(error) || !await _owner._rootsAddedFor(url)) {
        rethrow;
      }
      return _inner.openUrl(method, url);
    }
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) =>
      _inner.open(method, host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('get', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('post', url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('put', url);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('delete', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('patch', url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('head', url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _inner.get(host, port, path);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _inner.post(host, port, path);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _inner.put(host, port, path);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _inner.delete(host, port, path);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _inner.patch(host, port, path);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _inner.head(host, port, path);

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) =>
      _inner.authenticate = f;
  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) =>
      _inner.addCredentials(url, realm, credentials);
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )? f,
  ) =>
      _inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
        f,
  ) =>
      _inner.authenticateProxy = f;
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) =>
      _inner.addProxyCredentials(host, port, realm, credentials);
  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) =>
      _inner.badCertificateCallback = callback;
  @override
  set keyLog(dynamic Function(String line)? callback) =>
      _inner.keyLog = callback;

  @override
  void close({bool force = false}) => _inner.close(force: force);
}
