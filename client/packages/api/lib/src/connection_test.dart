// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The connection test: latency, download and upload speed to the server, once
/// per route a device can take, measured one after another.
library;

import 'dart:math' as math;

import 'exceptions.dart';
import 'upload_source.dart';

/// Which path a measurement took.
enum ConnectionRoute { lan, internet }

/// One timed transfer.
class ProbeTransfer {
  const ProbeTransfer(this.bytes, this.elapsed);

  final int bytes;
  final Duration elapsed;

  /// Infinite for an instant transfer; [capSpeed] puts a ceiling on what is shown.
  double get bitsPerSecond => bytes <= 0
      ? 0
      : elapsed.inMicroseconds <= 0
          ? double.infinity
          : bytes * 8 * 1e6 / elapsed.inMicroseconds;
}

/// What the test needs from one route; a seam for tests, which have no network.
abstract interface class ConnectionProbe {
  /// Whether the server's answers came through Cloudflare, once one has.
  bool get viaCloudflare;

  Future<Duration> ping({UploadCancelToken? cancel});

  Future<ProbeTransfer> download(
    int bytes, {
    UploadCancelToken? cancel,
    void Function(int done)? onProgress,
  });

  Future<ProbeTransfer> upload(
    int bytes, {
    UploadCancelToken? cancel,
    void Function(int done)? onProgress,
  });

  void close();
}

/// How one route measured, or why it could not be.
class RouteMeasurement {
  const RouteMeasurement({
    required this.route,
    this.latency,
    this.downloadBps,
    this.uploadBps,
    this.viaCloudflare = false,
    this.failure,
  });

  final ConnectionRoute route;
  final Duration? latency;
  final double? downloadBps;
  final double? uploadBps;
  final bool viaCloudflare;

  /// Why the route could not be measured, in words a person can read.
  final String? failure;
}

/// Where a running test is: the step in words, and how far along overall.
class ConnectionTestProgress {
  const ConnectionTestProgress(this.route, this.step, this.fraction);

  final ConnectionRoute route;
  final String step;
  final double fraction;
}

/// Whether [host] is this machine or a private network, where a speed is the
/// local network's and calling it "Internet" would be wrong.
bool isLocalHost(String host) {
  final name = host.toLowerCase();
  if (name == 'localhost' || name.endsWith('.local')) return true;
  if (name == '::1' || name.startsWith('fc') && name.contains(':')) return true;
  if (name.startsWith('fd') && name.contains(':')) return true;
  if (name.startsWith('fe80:')) return true;
  final parts = name.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null || p < 0 || p > 255)) {
    return false;
  }
  final [a, b, ...] = parts.cast<int>();
  return a == 127 ||
      a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254);
}

const kPingSamples = 5;
const _warmUpBytes = 1024 * 1024;

/// Under the server's own 64 MiB cap on a diagnostics transfer.
const _maxBytes = 64 * 1024 * 1024;
const _targetSeconds = 2;

/// Below this the warm-up is all a slow link can afford, so it is the result.
const _minMeasuredBytes = 2 * 1024 * 1024;

/// Above this a single phone-to-server transfer is not trustworthy, so it is
/// reported as "at least" this much.
const kMaxReportedBps = 10e9;

/// A speed no higher than [kMaxReportedBps].
double capSpeed(double bitsPerSecond) =>
    math.min(bitsPerSecond, kMaxReportedBps);

/// Runs each probe in turn and measures latency, download and upload.
///
/// A route that cannot be reached is reported as a failure of that route; it
/// never stops the others. Cancelling through [cancel] throws
/// [UploadCancelled].
Future<List<RouteMeasurement>> runConnectionTest(
  List<(ConnectionRoute, ConnectionProbe)> probes, {
  UploadCancelToken? cancel,
  void Function(ConnectionTestProgress progress)? onProgress,
}) async {
  const stepsPerRoute = kPingSamples + 1 + 2 + 2;
  final total = probes.length * stepsPerRoute;
  var done = 0;
  final results = <RouteMeasurement>[];
  for (final (route, probe) in probes) {
    void step(String name, [int count = 1]) {
      done += count;
      onProgress?.call(ConnectionTestProgress(route, name, done / total));
    }

    onProgress?.call(
      ConnectionTestProgress(route, 'Checking latency', done / total),
    );
    try {
      final latency =
          await _latency(probe, cancel, () => step('Checking latency'));
      step('Testing download', 0);
      final down = await _transfer(
          probe.download, cancel, () => step('Testing download'));
      step('Testing upload', 0);
      final up =
          await _transfer(probe.upload, cancel, () => step('Testing upload'));
      results.add(RouteMeasurement(
        route: route,
        latency: latency,
        downloadBps: down,
        uploadBps: up,
        viaCloudflare: probe.viaCloudflare,
      ));
    } on UploadCancelled {
      rethrow;
    } on ApiException catch (e) {
      done = (results.length + 1) * stepsPerRoute;
      results.add(RouteMeasurement(
        route: route,
        viaCloudflare: probe.viaCloudflare,
        failure: _words(e),
      ));
    } finally {
      probe.close();
    }
  }
  return results;
}

String _words(ApiException e) => switch (e) {
      RateLimitedException() => 'Too many tests, try again in a minute.',
      UnauthorizedException() => 'Sign in again to run it.',
      TransportException() => 'Could not reach the server this way.',
      _ => 'The server refused the test.',
    };

/// A warm-up ping that opens the connection, then the median of the timed ones.
Future<Duration> _latency(
  ConnectionProbe probe,
  UploadCancelToken? cancel,
  void Function() tick,
) async {
  await probe.ping(cancel: cancel);
  tick();
  final samples = <Duration>[];
  for (var i = 0; i < kPingSamples; i++) {
    cancel?.throwIfCancelled();
    samples.add(await probe.ping(cancel: cancel));
    tick();
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

typedef _Transfer = Future<ProbeTransfer> Function(
  int bytes, {
  UploadCancelToken? cancel,
  void Function(int done)? onProgress,
});

/// A warm-up transfer that opens the congestion window and sizes the real one,
/// then a measured transfer meant to last a couple of seconds. The warm-up is
/// the result only when the link is too slow to afford a second transfer.
Future<double> _transfer(
  _Transfer run,
  UploadCancelToken? cancel,
  void Function() tick,
) async {
  cancel?.throwIfCancelled();
  final warmUp = await run(_warmUpBytes, cancel: cancel);
  tick();
  final fit = measuredBytes(warmUp.bitsPerSecond);
  if (fit < _minMeasuredBytes) {
    tick();
    return capSpeed(warmUp.bitsPerSecond);
  }
  cancel?.throwIfCancelled();
  final measured = await run(fit, cancel: cancel);
  tick();
  return capSpeed(measured.bitsPerSecond);
}

/// How many bytes to move to keep a link of [bitsPerSecond] busy for the
/// target time, under the server's cap.
int measuredBytes(double bitsPerSecond) {
  final fit = bitsPerSecond / 8 * _targetSeconds;
  return math.min(fit, _maxBytes.toDouble()).floor();
}
