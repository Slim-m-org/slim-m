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
}

/// The `host:port` entries a client may dial: an IP literal in a private or
/// loopback range, on [publicPort], the server's own port. A server is
/// untrusted input here (the app can hold several), so anything else, a
/// public address, a hostname or another port, would let it aim this device's
/// connections at services it never meant to reach.
List<({String host, int port})> parseDirectAddresses(
  List<String> raw, {
  required int publicPort,
}) =>
    [
      for (final entry in raw)
        if (entry.lastIndexOf(':') case final colon when colon > 0)
          if (int.tryParse(entry.substring(colon + 1)) case final port?
              when port == publicPort)
            if (_lanHost(entry.substring(0, colon)) case final host?)
              (host: host, port: port),
    ];

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
