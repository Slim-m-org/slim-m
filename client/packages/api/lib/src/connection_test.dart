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

  double get bitsPerSecond => elapsed.inMicroseconds <= 0
      ? 0
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

const kPingSamples = 5;
const _probeBytes = 1024 * 1024;

/// Under the server's own 25 MiB cap on a diagnostics transfer.
const _maxBytes = 24 * 1024 * 1024;
const _targetSeconds = 3;

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

/// A small transfer to learn the speed, then one sized to last a few seconds
/// when the link is fast enough to make that worthwhile.
Future<double> _transfer(
  _Transfer run,
  UploadCancelToken? cancel,
  void Function() tick,
) async {
  cancel?.throwIfCancelled();
  final probe = await run(_probeBytes, cancel: cancel);
  tick();
  final fit = probe.bitsPerSecond / 8 * _targetSeconds;
  if (fit <= _probeBytes * 2) {
    tick();
    return probe.bitsPerSecond;
  }
  cancel?.throwIfCancelled();
  final full =
      await run(math.min(fit, _maxBytes.toDouble()).floor(), cancel: cancel);
  tick();
  return full.bitsPerSecond;
}
