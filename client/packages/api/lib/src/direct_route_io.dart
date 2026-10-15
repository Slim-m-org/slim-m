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
    DateTime Function()? clock,
  })  : _context = context,
        _connectPublic = connectPublic,
        _clock = clock ?? DateTime.now {
    _client.connectionFactory = _connect;
  }

  final Uri _base;
  final SecurityContext? _context;
  final PublicConnect? _connectPublic;
  final DateTime Function() _clock;
  final HttpClient _client = HttpClient();

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

  @override
  bool get active => _active;

  @override
  late final http.Client httpClient = IOClient(_client);

  @override
  void advertise(List<String> addresses) {
    final parsed = parseDirectAddresses(addresses);
    if (_same(parsed, _addresses)) return;
    _addresses = parsed;
    _next = 0;
    _skipUntil = null;
    _penalty = _firstPenalty;
    if (parsed.isEmpty) _active = false;
  }

  @override
  WebSocketChannel connectWebSocket(Uri url) =>
      IOWebSocketChannel.connect(url, customClient: _client);

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
      raw = await Socket.connect(
        to.host,
        to.port,
        timeout: _directConnectTimeout,
      );
      final socket = await SecureSocket.secure(
        raw,
        host: url.host,
        context: _context,
      ).timeout(_handshakeTimeout);
      _active = true;
      _penalty = _firstPenalty;
      _skipUntil = null;
      return socket;
    } on Object {
      raw?.destroy();
      _active = false;
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
