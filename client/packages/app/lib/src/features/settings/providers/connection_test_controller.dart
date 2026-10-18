// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Runs the connection test on request and holds what it found.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

/// The probes for each route a test would measure; a seam for tests.
final connectionProbesProvider =
    Provider<List<(ConnectionRoute, ConnectionProbe)> Function()>(
      (ref) => ref.read(apiProvider).connectionProbes,
    );

/// Whether requests take the server's own network right now.
final connectionLanInUseProvider = Provider<bool Function()>(
  (ref) =>
      () => ref.read(apiProvider).usesDirectRoute,
);

class ConnectionTestState {
  const ConnectionTestState({
    this.running = false,
    this.progress,
    this.results,
    this.inUse,
    this.failed = false,
  });

  final bool running;
  final ConnectionTestProgress? progress;
  final List<RouteMeasurement>? results;

  /// The route requests take right now, when the test measured more than one.
  final ConnectionRoute? inUse;

  /// The test stopped for a reason outside any one route.
  final bool failed;
}

class ConnectionTestController extends StateNotifier<ConnectionTestState> {
  ConnectionTestController(this._ref) : super(const ConnectionTestState());

  final Ref _ref;
  UploadCancelToken? _cancel;

  Future<void> run() async {
    if (state.running) return;
    final cancel = _cancel = UploadCancelToken();
    state = const ConnectionTestState(running: true);
    final probes = _ref.read(connectionProbesProvider)();
    final inUse = probes.length > 1 && _ref.read(connectionLanInUseProvider)()
        ? ConnectionRoute.lan
        : ConnectionRoute.internet;
    try {
      final results = await runConnectionTest(
        probes,
        cancel: cancel,
        onProgress: (progress) {
          if (mounted) {
            state = ConnectionTestState(running: true, progress: progress);
          }
        },
      );
      if (!mounted) return;
      state = ConnectionTestState(
        results: results,
        inUse: probes.length > 1 ? inUse : null,
      );
    } on UploadCancelled {
      if (mounted) state = const ConnectionTestState();
    } on Object catch (error, stack) {
      reportFailure(LogTag.net, 'run the connection test', error, stack);
      if (mounted) state = const ConnectionTestState(failed: true);
    }
  }

  void stop() => _cancel?.cancel();

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }
}

final connectionTestProvider =
    StateNotifierProvider.autoDispose<
      ConnectionTestController,
      ConnectionTestState
    >(ConnectionTestController.new);
