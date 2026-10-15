// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A shortcut to the server over its own network, for a deployment behind a
/// proxy such as Cloudflare that caps how fast a home upload can go.
///
/// The server advertises `host:port` addresses in `/version`. On a native
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

abstract interface class DirectRoute {
  factory DirectRoute(Uri baseUrl) => createDirectRoute(baseUrl);

  /// Replaces the addresses to try, from the server's `/version`.
  void advertise(List<String> addresses);

  /// Whether the last connection went over an advertised address.
  bool get active;

  /// The HTTP client every request to the server goes through.
  http.Client get httpClient;

  /// Opens the event socket over the same route.
  WebSocketChannel connectWebSocket(Uri url);
}

/// `host:port` entries split apart; anything else is dropped.
List<({String host, int port})> parseDirectAddresses(List<String> raw) => [
      for (final entry in raw)
        if (entry.lastIndexOf(':') case final colon when colon > 0)
          if (int.tryParse(entry.substring(colon + 1)) case final port?
              when port > 0 && port < 65536)
            (host: entry.substring(0, colon), port: port),
    ];
