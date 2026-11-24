// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A shortcut to the server over its own network, for a deployment behind a
/// proxy such as Cloudflare that caps how fast a home upload can go.
///
/// A signed-in client reads the server's `host:port` addresses from
/// `GET /direct-route`, never from the public `/version`. On a native
/// build every connection to the server's own hostname tries the advertised
/// address first and runs TLS with the real hostname, so the certificate is
/// checked exactly as it would be over the public route: an address that is
/// not this deployment (a different network reusing the same private range)
/// fails the handshake, and the connection falls back to the public route.
/// The web build has no say over how the browser connects, so it never
/// shortcuts.
library;

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'direct_route_web.dart' if (dart.library.io) 'direct_route_io.dart';
import 'logging/app_log.dart';

abstract interface class DirectRoute {
  factory DirectRoute(Uri baseUrl) => createDirectRoute(baseUrl);

  /// Replaces the addresses to try, from the server's `/version`.
  void advertise(List<String> addresses);

  /// Whether the last connection went over an advertised address.
  bool get active;

  /// Each new [active] value, only when it differs from the last one.
  Stream<bool> get activeChanges;

  /// The HTTP client every request to the server goes through.
  http.Client get httpClient;

  /// Opens the event socket over the same route.
  WebSocketChannel connectWebSocket(Uri url);

  /// Opens a socket to [url] on a host beside the server's, such as a call's
  /// signalling, over the advertised address while requests take it. Null
  /// when that is not open to it or the attempt failed: connect normally.
  Future<WebSocketChannel?> connectSiblingDirect(
    Uri url, {
    Map<String, String>? headers,
  });

  /// Forgets a back-off after a failed attempt, so the next request tries the
  /// advertised address again. For work worth a few hundred milliseconds of
  /// probing, such as the start of a large upload.
  void retryNow();

  /// Drops connections kept alive over the advertised address. Called when the
  /// device may have changed network, since a pooled LAN socket then stalls
  /// until a request deadline instead of failing.
  void invalidate();

  /// Whether the server advertised an address a connection test can pin to.
  bool get hasAddresses;

  /// How many times the connection pool has been replaced; a request that
  /// spans a change opened a fresh connection.
  int get poolRenewals;

  /// A client that stays on one route and never falls back: the advertised
  /// address when [direct], the public hostname otherwise. Null when [direct]
  /// is asked for and there is no address. The caller closes it.
  http.Client? pinnedClient({required bool direct});
}

/// The ports a direct route may use: the public route has to be one of them
/// too, so a server on a service port cannot aim this device at that service.
const directRoutePorts = {443, 8443};

/// The `host:port` entries a client may dial: an IP literal in a private or
/// loopback range, on [publicPort], the server's own port, which must be one
/// of [directRoutePorts]. A server is untrusted input here (the app can hold
/// several), so anything else, a public address, a hostname or another port,
/// would let it aim this device's connections at services it never meant to
/// reach. Loopback is this device itself, so it is only taken when
/// [publicHost] is loopback too.
List<({String host, int port})> parseDirectAddresses(
  List<String> raw, {
  required int publicPort,
  required String publicHost,
}) {
  if (!directRoutePorts.contains(publicPort)) return const [];
  final loopbackAllowed = _isLoopback(publicHost);
  return [
    for (final entry in raw)
      if (entry.lastIndexOf(':') case final colon when colon > 0)
        if (int.tryParse(entry.substring(colon + 1)) case final port?
            when port == publicPort)
          if (_lanHost(entry.substring(0, colon)) case final host?
              when loopbackAllowed || !_isLoopback(host))
            (host: host, port: port),
  ];
}

bool _isLoopback(String host) {
  final bare = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  if (bare == 'localhost') return true;
  final v4 = _quietBytes(Uri.parseIPv4Address, bare);
  if (v4 != null) return v4[0] == 127;
  final v6 = _quietBytes(Uri.parseIPv6Address, bare);
  if (v6 == null) return false;
  final mapped =
      v6.take(10).every((b) => b == 0) && v6[10] == 0xff && v6[11] == 0xff;
  if (mapped) return v6[12] == 127;
  return v6.take(15).every((b) => b == 0) && v6[15] == 1;
}

List<int>? _quietBytes(List<int> Function(String) parse, String host) {
  try {
    return parse(host);
  } on FormatException {
    return null;
  }
}

/// Whether [host] is one the proxy at an advertised address may also serve:
/// [server] itself, a subdomain of it, or a sibling under its parent domain,
/// as `livekit.example.com` is beside `slim.example.com`. The TLS handshake
/// then proves the proxy does serve it.
bool siblingHost(String host, String server) {
  if (host == server) return true;
  if (_ipLiteral(host) || _ipLiteral(server)) return false;
  if (host.endsWith('.$server')) return true;
  final parent = _parentDomain(server);
  return parent != null && _parentDomain(host) == parent;
}

/// Everything after the first label, when that is still a domain of two labels or more.
String? _parentDomain(String host) {
  final dot = host.indexOf('.');
  if (dot < 0) return null;
  final parent = host.substring(dot + 1);
  return parent.contains('.') ? parent : null;
}

bool _ipLiteral(String host) =>
    host.contains(':') || RegExp(r'^[0-9.]+$').hasMatch(host);

/// [host] without IPv6 brackets when it is a private or loopback IP literal.
String? _lanHost(String host) {
  final bare = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  final v4 = _bytes(Uri.parseIPv4Address, bare);
  if (v4 != null) return _privateV4(v4) ? bare : null;
  final v6 = _bytes(Uri.parseIPv6Address, bare);
  if (v6 == null) return null;
  final mapped =
      v6.take(10).every((b) => b == 0) && v6[10] == 0xff && v6[11] == 0xff;
  if (mapped) return _privateV4(v6.sublist(12)) ? bare : null;
  final loopback = v6.take(15).every((b) => b == 0) && v6[15] == 1;
  final uniqueLocal = v6[0] & 0xfe == 0xfc;
  final linkLocal = v6[0] == 0xfe && v6[1] & 0xc0 == 0x80;
  return loopback || uniqueLocal || linkLocal ? bare : null;
}

List<int>? _bytes(List<int> Function(String) parse, String host) {
  try {
    return parse(host);
  } on FormatException catch (error, stack) {
    AppLog.swallowed(
        LogTag.net,
        'The direct route address is malformed; using the normal route',
        error,
        stack);
    return null;
  }
}

bool _privateV4(List<int> b) =>
    b[0] == 10 ||
    b[0] == 127 ||
    (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
    (b[0] == 192 && b[1] == 168) ||
    (b[0] == 169 && b[1] == 254);
