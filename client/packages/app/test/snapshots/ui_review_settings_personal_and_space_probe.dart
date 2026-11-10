// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Connection probes with fixed numbers, for the Troubleshooting connection
/// test review cases: one held mid-run, and a LAN plus an internet result.
library;

import 'dart:async';

import 'package:slimm_api/api.dart';

class ReviewProbe implements ConnectionProbe {
  ReviewProbe({
    this.latencyMs = 2,
    this.downMbps = 480,
    this.upMbps = 310,
    this.cloudflare = false,
    this.gate,
  });

  final int latencyMs;
  final double downMbps;
  final double upMbps;
  final bool cloudflare;

  /// Holds the first ping until completed, which is what a mid-run capture needs.
  final Completer<void>? gate;

  @override
  bool get viaCloudflare => cloudflare;

  @override
  Future<Duration> ping({UploadCancelToken? cancel}) async {
    await gate?.future;
    cancel?.throwIfCancelled();
    return Duration(milliseconds: latencyMs);
  }

  ProbeTransfer _move(int bytes, double mbps) =>
      ProbeTransfer(bytes, Duration(microseconds: (bytes * 8 / mbps).round()));

  @override
  Future<ProbeTransfer> download(
    int bytes, {
    UploadCancelToken? cancel,
    void Function(int done)? onProgress,
  }) async => _move(bytes, downMbps);

  @override
  Future<ProbeTransfer> upload(
    int bytes, {
    UploadCancelToken? cancel,
    void Function(int done)? onProgress,
  }) async => _move(bytes, upMbps);

  @override
  void close() {}
}

typedef ReviewProbes = List<(ConnectionRoute, ConnectionProbe)>;

ReviewProbes runningProbes(Completer<void> gate) => [
  (ConnectionRoute.internet, ReviewProbe(gate: gate)),
];

ReviewProbes resultProbes(Completer<void> gate) => [
  (ConnectionRoute.lan, ReviewProbe()),
  (
    ConnectionRoute.internet,
    ReviewProbe(latencyMs: 31, downMbps: 87, upMbps: 5.4, cloudflare: true),
  ),
];
