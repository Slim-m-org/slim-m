// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:convert';
import 'client.dart';
import 'client_metrics_parser.dart';
import 'client_transport.dart';

/// `GET /metrics`: Prometheus text exposition, decoded into typed
/// aggregates for the admin metrics screen. Requires MANAGE_SERVER, the
/// same bit `/space/analytics` and `/space/storage` require.
///
/// The response is `text/plain`, not JSON, so this goes through
/// [fetchBytes] rather than [send] - the same seam the
/// three byte-fetching routes already use - and parses the text itself
/// rather than pulling in a Prometheus client library for one endpoint.
extension SlimmApiMetrics on SlimmApi {
  Future<ServerMetrics> fetchServerMetrics() async {
    final fetched = await fetchBytes('/metrics');
    return parsePrometheusMetrics(utf8.decode(fetched.bytes));
  }
}

/// One method-and-route's request-latency histogram, decoded from the
/// server's `slimm_http_request_duration_seconds` series.
class RouteMetric {
  const RouteMetric({
    required this.method,
    required this.route,
    required this.count,
    required this.sumSeconds,
    required this.p95Seconds,
  });

  final String method;
  final String route;

  /// Requests observed since the server process started.
  final int count;
  final double sumSeconds;

  /// A linear-interpolation estimate over the histogram's buckets, the same
  /// approximation `histogram_quantile` uses in PromQL. Null when [count] is
  /// zero: there is nothing to estimate a quantile over.
  final double? p95Seconds;

  double get avgSeconds => count == 0 ? 0 : sumSeconds / count;
}

/// One rate-limit class's admitted and refused request counts, from
/// `slimm_requests_total` and `slimm_requests_refused_total`.
class RequestClassCount {
  const RequestClassCount({
    required this.className,
    required this.admitted,
    required this.refused,
  });

  final String className;
  final int admitted;
  final int refused;
}

/// SQLite pool occupancy, from the `slimm_db_pool_connections*` gauges.
class DbPoolStats {
  const DbPoolStats({
    required this.max,
    required this.size,
    required this.inUse,
  });

  final int max;
  final int size;
  final int inUse;
}

/// The whole `/metrics` scrape, typed and ready for the admin screen.
class ServerMetrics {
  const ServerMetrics({
    required this.residentMemoryBytes,
    required this.webSocketConnections,
    required this.requestsByClass,
    required this.pool,
    required this.routes,
  });

  /// Null when the platform could not answer (`NaN` on the wire), not zero.
  final double? residentMemoryBytes;
  final int webSocketConnections;
  final List<RequestClassCount> requestsByClass;

  /// Null only if the server predates the pool gauges.
  final DbPoolStats? pool;

  /// Every method-and-route combination observed so far, unsorted - the
  /// caller picks its own order (busiest, slowest, alphabetical).
  final List<RouteMetric> routes;
}
