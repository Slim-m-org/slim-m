// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting connection test: idle until asked, cancellable with
/// progress, and plain about which route each number belongs to.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/providers/connection_test_controller.dart';
import 'package:slimm_app/src/features/settings/widgets/connection_test_format.dart';
import 'package:slimm_app/src/features/settings/widgets/connection_test_row.dart';
import 'package:slimm_design_system/design_system.dart';

class _Probe implements ConnectionProbe {
  _Probe({
    this.latencyMs = 2,
    this.downMbps = 480,
    this.upMbps = 310,
    this.cloudflare = false,
    this.failure,
    this.gate,
  });

  final int latencyMs;
  final double downMbps;
  final double upMbps;
  final bool cloudflare;
  final ApiException? failure;

  /// Holds the first ping until completed, so a test can look mid-run.
  final Completer<void>? gate;
  var closed = false;

  @override
  bool get viaCloudflare => cloudflare;

  @override
  Future<Duration> ping({UploadCancelToken? cancel}) async {
    if (failure case final error?) throw error;
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
  void close() => closed = true;
}

Future<void> _pump(
  WidgetTester tester,
  List<(ConnectionRoute, ConnectionProbe)> Function() probes, {
  bool lanInUse = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProbesProvider.overrideWithValue(probes),
        connectionLanInUseProvider.overrideWithValue(() => lanInUse),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: ConnectionTestRow()),
      ),
    ),
  );
}

void main() {
  testWidgets('starts nothing until Run is pressed', (tester) async {
    var asked = 0;
    await _pump(tester, () {
      asked++;
      return [(ConnectionRoute.internet, _Probe())];
    });
    expect(find.text('Connection test'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
    expect(asked, 0);
  });

  testWidgets('shows both routes and marks the one in use', (tester) async {
    await _pump(
      tester,
      () => [
        (ConnectionRoute.lan, _Probe()),
        (
          ConnectionRoute.internet,
          _Probe(latencyMs: 31, downMbps: 87, upMbps: 5.4, cloudflare: true),
        ),
      ],
      lanInUse: true,
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Run'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(
      find.textContaining('LAN (in use): 2 ms, 480 Mbps down, 310 Mbps up'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Internet (Cloudflare): 31 ms, 87 Mbps down, 5.4 Mbps up',
      ),
      findsOneWidget,
    );
    expect(find.text('Run again'), findsOneWidget);
  });

  testWidgets('a single route is not labelled in use', (tester) async {
    await _pump(tester, () => [(ConnectionRoute.internet, _Probe())]);
    await tester.runAsync(() async {
      await tester.tap(find.text('Run'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.textContaining('Internet: 2 ms'), findsOneWidget);
    expect(find.textContaining('in use'), findsNothing);
  });

  testWidgets('a route that fails says so beside the one that worked', (
    tester,
  ) async {
    await _pump(
      tester,
      () => [
        (
          ConnectionRoute.lan,
          _Probe(failure: const TransportException('unreachable')),
        ),
        (ConnectionRoute.internet, _Probe()),
      ],
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Run'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(
      find.textContaining('LAN: Could not reach the server this way.'),
      findsOneWidget,
    );
    expect(find.textContaining('Internet (in use): 2 ms'), findsOneWidget);
  });

  testWidgets('shows progress while running and Stop puts it back', (
    tester,
  ) async {
    final gate = Completer<void>();
    final probe = _Probe(gate: gate);
    await _pump(tester, () => [(ConnectionRoute.internet, probe)]);

    await tester.tap(find.text('Run'));
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('Checking latency'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.runAsync(() async {
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.text('Run'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('Mbps'), findsNothing);
    expect(probe.closed, isTrue);
  });

  test('speeds and latency read plainly', () {
    expect(formatSpeed(5.4e6), '5.4 Mbps');
    expect(formatSpeed(480e6), '480 Mbps');
    expect(formatSpeed(1.25e9), '1.3 Gbps');
    expect(formatSpeed(16.2e9), '10+ Gbps');
    expect(formatLatency(const Duration(microseconds: 400)), 'under 1 ms');
    expect(formatLatency(const Duration(milliseconds: 31)), '31 ms');
  });
}
