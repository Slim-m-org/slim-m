// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The live connection report: timed requests to the server, the call's legs, and a Cloudflare trace of the call's host.
///
/// Nothing here runs on a timer: the server is timed when something first
/// watches this, when a call starts or comes back from a repair, and on a
/// check; the call's host is traced at the same moments in a call. Only the
/// trace's data centre is kept.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/providers.dart';
import '../../voice/providers/voice_controller.dart';
import '../connection_route.dart';

/// The report and the concern it raises once smoothed by [RouteWatch].
typedef ConnectionStatus = ({ConnectionReport report, RouteConcern? concern});

final connectionStatusProvider =
    NotifierProvider.autoDispose<ConnectionStatusNotifier, ConnectionStatus>(
      ConnectionStatusNotifier.new,
    );

class ConnectionStatusNotifier extends AutoDisposeNotifier<ConnectionStatus> {
  late SlimmApi _api;
  late VoiceHealth _health;
  final _watch = RouteWatch();
  EdgeTrace? _signalTrace;
  bool _hadCall = false;
  bool _repairing = false;
  bool _gone = false;

  @override
  ConnectionStatus build() {
    _api = ref.watch(apiProvider);
    _health = ref.watch(voiceControllerProvider.notifier).health;
    final edge = _api.edge.changes.listen((_) => _recompute());
    final repair = _health.reconnect.active;
    _health.link.addListener(_onCall);
    repair.addListener(_onRepair);
    _gone = false;
    ref.onDispose(() {
      _gone = true;
      unawaited(edge.cancel());
      _health.link.removeListener(_onCall);
      repair.removeListener(_onRepair);
    });
    _hadCall = _health.link.value != null;
    _repairing = repair.value;
    unawaited(refresh());
    return _read();
  }

  /// Times the server now and, in a call, traces the call's host again.
  Future<void> refresh() async {
    await Future.wait([
      _api.measureRoundTrip(),
      if (_health.link.value != null) _traceSignal(),
    ]);
  }

  void _onCall() {
    final inCall = _health.link.value != null;
    if (inCall && !_hadCall) unawaited(refresh());
    if (!inCall) _signalTrace = null;
    _hadCall = inCall;
    _recompute();
  }

  // A repaired signalling socket may have landed in another data centre.
  void _onRepair() {
    final repairing = _health.reconnect.active.value;
    if (_repairing && !repairing && _health.link.value != null) {
      unawaited(refresh());
    }
    _repairing = repairing;
  }

  Future<void> _traceSignal() async {
    final url = _health.signalUrl;
    if (url == null) return;
    final trace = await _api.cloudflareTrace(host: url);
    if (_health.link.value == null) return;
    _signalTrace = trace;
    _recompute();
  }

  ConnectionStatus _read() {
    final report = connectionReportOf(
      server: _api.edge.last,
      signalTrace: _signalTrace,
      call: _health.link.value,
    );
    return (report: report, concern: _watch.update(report, DateTime.now()));
  }

  void _recompute() {
    // A trace can land after the last watcher left.
    if (!_gone) state = _read();
  }
}
