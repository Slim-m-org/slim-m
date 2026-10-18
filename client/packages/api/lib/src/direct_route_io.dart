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
  })  : _context = context,
        _connectPublic = connectPublic,
        _connectDirect = connectDirect,
        _clock = clock ?? DateTime.now {
    _client = _freshClient();
  }

  final Uri _base;
  final SecurityContext? _context;
  final PublicConnect? _connectPublic;
  final PublicConnect? _connectDirect;
  final DateTime Function() _clock;

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
  static const _firstPenalty = Duration(minutes: 1);
  static const _maxPenalty = Duration(minutes: 15);

  List<({String host, int port})> _addresses = const [];
  int _next = 0;
  DateTime? _skipUntil;
  Duration _penalty = _firstPenalty;
  bool _active = false;
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
    _skipUntil = null;
    _penalty = _firstPenalty;
    if (parsed.isEmpty) _isActive = false;
    _renewPool();
  }

  @override
  WebSocketChannel connectWebSocket(Uri url) =>
      IOWebSocketChannel.connect(url, customClient: _currentClient());

  HttpClient _freshClient() => HttpClient()..connectionFactory = _connect;

  /// The pool to use now, renewed when a direct attempt is due and the
  /// current pool would otherwise keep reusing a public connection.
  HttpClient _currentClient() {
    final skip = _skipUntil;
    final due = _addresses.isNotEmpty &&
        !_active &&
        !_probing &&
        (skip == null || !_clock().isBefore(skip));
    if (due) _renewPool();
    return _client;
  }

  void _renewPool() {
    final old = _client;
    _client = _freshClient();
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
    final skip = _skipUntil;
    if (skip != null && _clock().isBefore(skip)) return null;
    return _addresses[_next % _addresses.length];
  }

  Future<Socket> _viaDirect(({String host, int port}) to, Uri url) async {
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
      final socket = await SecureSocket.secure(
        raw,
        host: url.host,
        context: _context,
      ).timeout(_handshakeTimeout);
      _isActive = true;
      _probing = false;
      _penalty = _firstPenalty;
      _skipUntil = null;
      return socket;
    } on Object {
      raw?.destroy();
      _isActive = false;
      _probing = false;
      _next++;
      _skipUntil = _clock().add(_penalty);
      _penalty = Duration(
        milliseconds: math.min(
          _penalty.inMilliseconds * 2,
          _maxPenalty.inMilliseconds,
        ),
      );
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
