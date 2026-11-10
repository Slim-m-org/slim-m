// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the session off a server whose key contradicts its pin until the
/// person chooses (decision 0036).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'server_identity_recheck.dart';

/// Whether the server presents a key that contradicts its pin and nobody has chosen yet.
/// A re-probe in flight keeps the answer it had, like the screen does.
final serverIdentityMismatchedProvider = Provider<bool>(
  (ref) => ref.watch(serverIdentityChangeProvider).valueOrNull != null,
);

/// Hands each API client the gate that holds its session back.
final serverIdentityGateProvider = Provider<ServerIdentityGate>(
  ServerIdentityGate.new,
);

/// The wait in front of every call that carries the session.
class ServerIdentityGate {
  ServerIdentityGate(this._ref);

  final Ref _ref;
  Future<void>? _chosen;

  /// A gate for one client: its server's first identity answer, then any mismatch that stands.
  /// An unreadable server, or one with nothing pinned, lets the session through.
  api.TrustGate forClient() {
    var answered = false;
    return () {
      if (answered && !_mismatched) return null;
      return _hold(() => answered = true);
    };
  }

  bool get _mismatched => _ref.read(serverIdentityMismatchedProvider);

  Future<void> _hold(void Function() markAnswered) async {
    try {
      await _ref.read(serverIdentityChangeProvider.future);
    } on Object catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.auth,
        'Could not check the server identity; letting the session through',
        error,
        stack,
      );
    }
    markAnswered();
    while (_mismatched) {
      await _untilChosen();
    }
  }

  /// One subscription for every call held at once, so a long wait does not stack listeners.
  Future<void> _untilChosen() =>
      _chosen ??= _watchForChoice().whenComplete(() => _chosen = null);

  Future<void> _watchForChoice() {
    final chosen = Completer<void>();
    final subscription = _ref.listen<bool>(serverIdentityMismatchedProvider, (
      _,
      mismatched,
    ) {
      if (!mismatched && !chosen.isCompleted) chosen.complete();
    });
    return chosen.future.whenComplete(subscription.close);
  }
}
