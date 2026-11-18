// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:http/http.dart' as http;

import 'client.dart';
import 'client_transport.dart';
import 'edge_route.dart';
import 'exceptions.dart';

/// How this device reaches the server: the data centre in between, and how long a round trip takes.
extension SlimmApiEdge on SlimmApi {
  /// The API's route as its own traffic shows it; see [EdgeWatch].
  EdgeWatch get edge => link.edge;

  /// Cloudflare's trace for [host] (default: this server), or null when no
  /// Cloudflare answers there, as on a self-host or the server's own network.
  Future<EdgeTrace?> cloudflareTrace({Uri? host}) async {
    final base = host ?? baseUrl;
    final scheme = switch (base.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      final other => other,
    };
    final uri = Uri(
      scheme: scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/cdn-cgi/trace',
    );
    try {
      // No deadline of its own: an answer that never comes only leaves the city unknown.
      final response = await link.client
          .send(http.Request('GET', uri))
          .then(http.Response.fromStream);
      if (response.statusCode != 200) return null;
      return parseCloudflareTrace(response.body);
    } on Object {
      return null;
    }
  }

  /// Times one request to the server now, and records it in [edge].
  Future<Duration?> measureRoundTrip() async {
    final clock = Stopwatch()..start();
    try {
      await send('GET', '/diagnostics/ping');
    } on ApiException {
      return null;
    }
    final elapsed = clock.elapsed;
    edge.noteRoundTrip(elapsed);
    return elapsed;
  }
}
