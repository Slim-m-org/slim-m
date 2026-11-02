// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A connectivity probe that cannot stall or fail a LiveKit join.
library;

import 'dart:async';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';

import 'voice_log.dart';

/// How long an unanswered probe is waited for before the host counts as online.
const connectivityProbeTimeout = Duration(seconds: 3);

/// Wraps the platform probe so an unanswered or failed query reads as online.
///
/// livekit_client awaits the probe on every join. On Linux it asks NetworkManager
/// over the system bus, which throws without NetworkManager (static IP, networkd,
/// iwd) and never completes when the bus socket is missing (Flatpak).
class GuardedConnectivity extends ConnectivityPlatform {
  GuardedConnectivity(
    this._inner, {
    this.timeout = connectivityProbeTimeout,
    VoiceLog? log,
  }) : _log = log;

  final ConnectivityPlatform _inner;
  final Duration timeout;
  final VoiceLog? _log;
  bool _degraded = false;

  /// Replaces the registered platform once; a second call keeps the first wrapper.
  static void install({VoiceLog? log}) {
    if (ConnectivityPlatform.instance is GuardedConnectivity) return;
    ConnectivityPlatform.instance =
        GuardedConnectivity(ConnectivityPlatform.instance, log: log);
  }

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    final answer = Completer<List<ConnectivityResult>>();
    // The D-Bus client reports a missing bus socket as an uncaught zone error.
    unawaited(runZonedGuarded(() async {
      try {
        final result = await _inner.checkConnectivity();
        if (!answer.isCompleted) answer.complete(result);
      } catch (error) {
        if (!answer.isCompleted) answer.completeError(error);
      }
    }, (error, _) {
      if (!answer.isCompleted) answer.completeError(error);
    }));
    try {
      final result = await answer.future.timeout(timeout);
      _degraded = false;
      return result;
    } catch (error) {
      _degraded = true;
      _log?.call('connectivity probe unanswered, assuming online: $error');
      return const [ConnectivityResult.other];
    }
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _degraded ? const Stream.empty() : _inner.onConnectivityChanged;
}
