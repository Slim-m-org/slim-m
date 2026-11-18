// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The live connection report: the API's own traffic, the call's legs, and Cloudflare's traces.
///
/// Traces are fetched on demand, when something first watches this and once
/// per call, never on a timer; only their data centre and country are kept.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/providers.dart';
import '../../voice/providers/voice_controller.dart';
import '../connection_route.dart';

/// The report and the concern it raises once smoothed by [RouteConcernGate].
typedef ConnectionStatus = ({ConnectionReport report, RouteConcern? concern});

final connectionStatusProvider =
    NotifierProvider.autoDispose<ConnectionStatusNotifier, ConnectionStatus>(
      ConnectionStatusNotifier.new,
    );

class ConnectionStatusNotifier extends AutoDisposeNotifier<ConnectionStatus> {
  late SlimmApi _api;
  late VoiceHealth _health;
  final _gate = RouteConcernGate();
  EdgeTrace? _serverTrace;
  EdgeTrace? _signalTrace;
  bool _hadCall = false;
  bool _gone = false;

  @override
  ConnectionStatus build() {
    _api = ref.watch(apiProvider);
    _health = ref.watch(voiceControllerProvider.notifier).health;
    final edge = _api.edge.changes.listen((_) => _recompute());
    final direct = _api.directRouteChanges.listen((_) => _recompute());
    _health.link.addListener(_onCall);
    _gone = false;
    ref.onDispose(() {
      _gone = true;
      unawaited(edge.cancel());
      unawaited(direct.cancel());
      _health.link.removeListener(_onCall);
    });
    unawaited(_traceServer());
    _hadCall = _health.link.value != null;
    if (_hadCall) unawaited(_traceSignal());
    return _read();
  }

  /// Measures the server leg now and asks Cloudflare again, for a person who opened the details.
  Future<void> refresh() async {
    await Future.wait([
      _api.measureRoundTrip(),
      _traceServer(),
      if (_health.link.value != null) _traceSignal(),
    ]);
  }

  void _onCall() {
    final inCall = _health.link.value != null;
    if (inCall && !_hadCall) unawaited(_traceSignal());
    if (!inCall) _signalTrace = null;
    _hadCall = inCall;
    _recompute();
  }

  Future<void> _traceServer() async {
    _serverTrace = await _api.cloudflareTrace();
    _recompute();
  }

  Future<void> _traceSignal() async {
    final url = _health.signalUrl;
    if (url == null) return;
    _signalTrace = await _api.cloudflareTrace(host: url);
    _recompute();
  }

  ConnectionStatus _read() {
    final edge = _api.edge;
    final report = connectionReportOf(
      direct: _api.usesDirectRoute,
      responded: edge.seen,
      apiColo: edge.colo,
      apiRoundTrip: edge.roundTrip,
      apiMeasuredAt: edge.measuredAt,
      serverTrace: _serverTrace,
      signalTrace: _signalTrace,
      call: _health.link.value,
      now: DateTime.now(),
    );
    return (report: report, concern: _gate.update(routeConcernOf(report)));
  }

  void _recompute() {
    // A trace can land after the last watcher left.
    if (!_gone) state = _read();
  }
}
