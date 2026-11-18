// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:http/http.dart' as http;

import 'client.dart';
import 'client_transport.dart';
import 'edge_route.dart';
import 'exceptions.dart';
import 'logging/app_log.dart';

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
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.net,
        'Could not read the Cloudflare trace',
        error,
        stack,
      );
      return null;
    }
  }

  /// Times one request to the server now, and records it in [edge] with the route it took.
  Future<EdgeReading?> measureRoundTrip({DateTime Function()? clock}) async {
    final watch = Stopwatch()..start();
    String? cfRay;
    try {
      await send(
        'GET',
        '/diagnostics/ping',
        onHeaders: (headers) => cfRay = headers['cf-ray'],
      );
    } on ApiException {
      return null;
    }
    final reading = EdgeReading(
      colo: cloudflareColoOf(cfRay),
      direct: usesDirectRoute,
      roundTrip: watch.elapsed,
      at: (clock ?? DateTime.now)(),
    );
    edge.note(reading);
    return reading;
  }
}
