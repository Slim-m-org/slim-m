// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:http/http.dart' as http;

import 'client.dart';
import 'client_transport.dart';
import 'edge_route.dart';
import 'exceptions.dart';

const _ping = '/diagnostics/ping';

// No deadline of its own: an answer that never comes only leaves the trace unread.
Future<http.Response> _traceOnce(http.Client client, Uri uri) async {
  try {
    return await client
        .send(http.Request('GET', uri))
        .then(http.Response.fromStream);
  } on http.ClientException catch (e) {
    throw ConnectionDroppedException('the trace of ${uri.host} failed: $e');
  } catch (e) {
    throw TransportException('the trace of ${uri.host} failed: $e');
  }
}

/// How this device reaches the server: the data centre in between, and how long a round trip takes.
extension SlimmApiEdge on SlimmApi {
  /// The API's route as its own traffic shows it; see [EdgeWatch].
  EdgeWatch get edge => link.edge;

  /// Cloudflare's trace for [host] (default: this server), or null when no
  /// Cloudflare answers there, as on a self-host or the server's own network.
  ///
  /// Throws a [TransportException] when nothing answered, which says nothing about the route.
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
    final response = await replayingDroppedSocket(
      'GET',
      () => _traceOnce(link.client, uri),
    );
    if (response.statusCode != 200) return null;
    return parseCloudflareTrace(response.body);
  }

  /// Times one warm request to the server now, and records it in [edge] with the route it took.
  ///
  /// An untimed ping first pays for connection setup and any token refresh; a
  /// timed one that still needed a replay, a refresh or a fresh pool is dropped.
  Future<EdgeReading?> measureRoundTrip({DateTime Function()? clock}) async {
    String? cfRay;
    final Duration roundTrip;
    try {
      await send('GET', _ping);
      final renewals = link.route?.poolRenewals;
      final watch = Stopwatch()..start();
      await send(
        'GET',
        _ping,
        once: true,
        onHeaders: (headers) => cfRay = headers['cf-ray'],
      );
      roundTrip = watch.elapsed;
      if (link.route?.poolRenewals != renewals) return null;
    } on ApiException {
      return null;
    }
    final reading = EdgeReading(
      colo: cloudflareColoOf(cfRay),
      direct: usesDirectRoute,
      roundTrip: roundTrip,
      at: (clock ?? DateTime.now)(),
    );
    edge.note(reading);
    return reading;
  }
}
