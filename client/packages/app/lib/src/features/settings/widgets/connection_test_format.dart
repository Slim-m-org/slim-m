// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The words for a connection test result.
library;

import 'package:slimm_api/api.dart';

/// "LAN", "Internet" or "Internet (Cloudflare)".
String routeLabel(RouteMeasurement m) => switch (m.route) {
  ConnectionRoute.lan => 'LAN',
  ConnectionRoute.internet =>
    m.viaCloudflare ? 'Internet (Cloudflare)' : 'Internet',
};

/// "480 Mbps", "5.4 Mbps", "1.2 Gbps" or "10+ Gbps" at the reporting cap.
String formatSpeed(double bitsPerSecond) {
  if (bitsPerSecond >= kMaxReportedBps) {
    return '${(kMaxReportedBps / 1e9).round()}+ Gbps';
  }
  final mbps = bitsPerSecond / 1e6;
  if (mbps >= 1000) return '${(mbps / 1000).toStringAsFixed(1)} Gbps';
  if (mbps >= 10) return '${mbps.round()} Mbps';
  return '${mbps.toStringAsFixed(1)} Mbps';
}

/// "2 ms", or "under 1 ms" on a fast local link.
String formatLatency(Duration latency) {
  final ms = latency.inMicroseconds / 1000;
  return ms < 1 ? 'under 1 ms' : '${ms.round()} ms';
}

/// "2 ms, 480 Mbps down, 310 Mbps up", or why the route could not be measured.
String describeMeasurement(RouteMeasurement m) {
  if (m.failure case final failure?) return failure;
  return [
    formatLatency(m.latency!),
    '${formatSpeed(m.downloadBps!)} down',
    '${formatSpeed(m.uploadBps!)} up',
  ].join(', ');
}
