// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native shortcut: connections to the server's hostname try an
/// advertised address first, with TLS against the real hostname.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'direct_route.dart';
import 'logging/app_log.dart';

DirectRoute createDirectRoute(Uri baseUrl) => IoDirectRoute(baseUrl);

/// How the public route connects; a seam for tests, which have no DNS name.
typedef PublicConnect = Future<Socket> Function(String host, int port);

class IoDirectRoute implements DirectRoute {
  IoDirectRoute(
    this._base, {
    SecurityContext? context,
    PublicConnect? connectPublic,
    PublicConnect? connectDirect,
    DateTime Function()? clock,
    String Function(Uri url)? findProxy,
  })  : _context = context,
        _connectPublic = connectPublic,
        _connectDirect = connectDirect,
        _clock = clock ?? DateTime.now,
        _findProxy = findProxy {
    _client = _freshClient();
  }

  final Uri _base;
  final SecurityContext? _context;
  final PublicConnect? _connectPublic;
  final PublicConnect? _connectDirect;
  final DateTime Function() _clock;

  /// Where requests go through a proxy; null keeps dart:io's environment lookup (https_proxy and friends).
  final String Function(Uri url)? _findProxy;

  /// The current pool. Kept-alive connections outlive the decision that
  /// opened them, so a route change starts a new pool; the old one finishes
  /// what it is carrying and closes.
  late HttpClient _client;

  /// A fresh pool is opened and its first connection has not settled yet.
  bool _probing = false;

  /// A reachable server on the same network answers in milliseconds; past
  /// this the address is not reachable from wherever the device is now.
  static const _directConnectTimeout = Duration(milliseconds: 700);
  static const _handshakeTimeout = Duration(seconds: 5);

  /// A sibling socket that has not opened by now goes the normal way, well inside LiveKit's 10 s connect deadline.
  static const _siblingTimeout = Duration(seconds: 3);

  List<({String host, int port})> _addresses = const [];
  int _next = 0;
  final _backoff = _Backoff();

  /// Kept apart, so a host the proxy does not serve never holds requests back.
  final _siblingBackoff = _Backoff();
  bool _active = false;
  int _renewals = 0;
  final _activeChanges = StreamController<bool>.broadcast();

  @override
  bool get active => _active;

  @override
  Stream<bool> get activeChanges => _activeChanges.stream;

  set _isActive(bool value) {
    if (value == _active) return;
    _active = value;
    if (!_activeChanges.isClosed) _activeChanges.add(value);
  }

  @override
  late final http.Client httpClient = _RoutedClient(this);

  @override
  void advertise(List<String> addresses) {
    final parsed = parseDirectAddresses(addresses, publicPort: _base.port);
    if (_same(parsed, _addresses)) return;
    _addresses = parsed;
    _next = 0;
    _backoff.reset();
    _siblingBackoff.reset();
    if (parsed.isEmpty) _isActive = false;
    _renewPool();
  }

  @override
  WebSocketChannel connectWebSocket(Uri url) =>
      IOWebSocketChannel.connect(url, customClient: _currentClient());

  HttpClient _freshClient() => _withProxyLookup(HttpClient(context: _context))
    ..connectionFactory = _connect;

  HttpClient _withProxyLookup(HttpClient client) {
    if (_findProxy case final find?) client.findProxy = find;
    return client;
  }

  /// The pool to use now, renewed when a direct attempt is due and the
  /// current pool would otherwise keep reusing a public connection.
  HttpClient _currentClient() {
    final due = _addresses.isNotEmpty &&
        !_active &&
        !_probing &&
        !_backoff.holds(_clock());
    if (due) _renewPool();
    return _client;
  }

  void _renewPool() {
    final old = _client;
    _client = _freshClient();
    _renewals++;
    _probing = _addresses.isNotEmpty;
    old.close();
  }

  void _close() {
    _client.close(force: true);
    _activeChanges.close();
  }

  Future<ConnectionTask<Socket>> _connect(
    Uri url,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (proxyHost != null && proxyPort != null) {
      // The client tunnels and starts TLS itself, so this hop stays a plain socket to the proxy.
      return Socket.startConnect(proxyHost, proxyPort);
    }
    final secure = url.isScheme('https');
    final direct = _candidate(url, secure);
    if (direct == null) {
      return ConnectionTask.fromSocket(_public(url, secure), () {});
    }
    return ConnectionTask.fromSocket(_viaDirect(direct, url), () {});
  }

  /// Only the server's own hostname, only over TLS, only while not backing off.
  ({String host, int port})? _candidate(Uri url, bool secure) {
    if (!secure || _addresses.isEmpty || url.host != _base.host) return null;
    if (_backoff.holds(_clock())) return null;
    return _addresses[_next % _addresses.length];
  }

  /// A host beside the server's, over TLS on its port, only while requests
  /// already take the advertised address: that is the proof this device is
  /// on the server's network now, so nothing is probed from elsewhere.
  ({String host, int port})? _siblingCandidate(Uri url) {
    final secure = url.isScheme('wss') || url.isScheme('https');
    final port = url.hasPort ? url.port : 443;
    if (!secure || !_active || _addresses.isEmpty) return null;
    if (port != _base.port || !siblingHost(url.host, _base.host)) return null;
    if (_siblingBackoff.holds(_clock())) return null;
    return _addresses[_next % _addresses.length];
  }

  @override
  Future<WebSocketChannel?> connectSiblingDirect(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    final to = _siblingCandidate(url);
    if (to == null) return null;
    final client = HttpClient(context: _context);
    client.connectionFactory = (target, proxyHost, proxyPort) async =>
        ConnectionTask.fromSocket(_dial(to, target), () {});
    // A LAN address is dialled itself, so no proxy can stand in for it.
    client.findProxy = (_) => 'DIRECT';
    final opening = WebSocket.connect(
      url.toString(),
      headers: headers,
      customClient: client,
    );
    try {
      final socket = await opening.timeout(_siblingTimeout);
      _siblingBackoff.reset();
      return IOWebSocketChannel(socket);
    } on Object catch (error) {
      _noteDirectFailure(
        'connect to ${url.host} over the direct route; using the normal route',
        error,
      );
      _siblingBackoff.fail(_clock());
      client.close(force: true);
      // A socket that opens past the deadline has nobody else to close it.
      unawaited(opening.then<void>((late) => late.close(), onError: (_) {}));
      return null;
    } finally {
      client.close();
    }
  }

  Future<SecureSocket> _dial(({String host, int port}) to, Uri url) async {
    Socket? raw;
    try {
      final connect = _connectDirect;
      raw = connect != null
          ? await connect(to.host, to.port).timeout(_directConnectTimeout)
          : await Socket.connect(
              to.host,
              to.port,
              timeout: _directConnectTimeout,
            );
      return await SecureSocket.secure(
        raw,
        host: url.host,
        context: _context,
      ).timeout(_handshakeTimeout);
    } on Object {
      raw?.destroy();
      rethrow;
    }
  }

  @override
  void retryNow() {
    if (_active) return;
    _backoff.reset();
  }

  @override
  void invalidate() {
    if (!_active) return;
    _isActive = false;
    _backoff.reset();
    _siblingBackoff.reset();
  }

  @override
  bool get hasAddresses => _addresses.isNotEmpty;

  @override
  int get poolRenewals => _renewals;

  @override
  http.Client? pinnedClient({required bool direct}) {
    if (direct && _addresses.isEmpty) return null;
    final to = _addresses.isEmpty ? null : _addresses.first;
    final client = _withProxyLookup(HttpClient(context: _context))
      ..connectionFactory = (url, proxyHost, proxyPort) async {
        if (proxyHost != null && proxyPort != null) {
          return Socket.startConnect(proxyHost, proxyPort);
        }
        return ConnectionTask.fromSocket(
          direct && to != null
              ? _dial(to, url)
              : _public(url, url.isScheme('https')),
          () {},
        );
      };
    // A LAN address is dialled itself, so no proxy can stand in for it.
    if (direct) client.findProxy = (_) => 'DIRECT';
    return IOClient(client);
  }

  Future<Socket> _viaDirect(({String host, int port}) to, Uri url) async {
    try {
      final socket = await _dial(to, url);
      _isActive = true;
      _probing = false;
      _backoff.reset();
      return socket;
    } on Object catch (error) {
      _noteDirectFailure(
        'connect over the direct route; using the normal route',
        error,
      );
      _isActive = false;
      _probing = false;
      _next++;
      _backoff.fail(_clock());
      return _public(url, true);
    }
  }

  Future<Socket> _public(Uri url, bool secure) async {
    final connect = _connectPublic;
    final raw = connect != null
        ? await connect(url.host, url.port)
        : await Socket.connect(url.host, url.port);
    if (!secure) return raw;
    return SecureSocket.secure(raw, host: url.host, context: _context);
  }

  static bool _same(
    List<({String host, int port})> a,
    List<({String host, int port})> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Logs a failed direct attempt by the error's type alone: its text names the
/// advertised address, and a debug log is something people share.
void _noteDirectFailure(String what, Object error) => AppLog.warning(
      LogTag.net,
      'Could not $what',
      context: {'failure': '${error.runtimeType}'},
    );

/// Waits a minute after a failed attempt, doubling up to fifteen while it keeps failing.
class _Backoff {
  static const _first = Duration(minutes: 1);
  static const _max = Duration(minutes: 15);

  DateTime? _until;
  Duration _penalty = _first;

  bool holds(DateTime now) {
    final until = _until;
    return until != null && now.isBefore(until);
  }

  void fail(DateTime now) {
    _until = now.add(_penalty);
    _penalty = Duration(
      milliseconds: math.min(_penalty.inMilliseconds * 2, _max.inMilliseconds),
    );
  }

  void reset() {
    _until = null;
    _penalty = _first;
  }
}

/// Sends each request through whichever pool the route holds at that moment.
class _RoutedClient extends http.BaseClient {
  _RoutedClient(this._route);

  final IoDirectRoute _route;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      IOClient(_route._currentClient()).send(request);

  @override
  void close() => _route._close();
}
