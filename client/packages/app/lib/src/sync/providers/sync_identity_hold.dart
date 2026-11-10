// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the sync stopped while the server's key contradicts its pin (decision 0036).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/providers/server_identity_hold.dart';
import '../../providers/providers.dart';

/// A changed server key is a stop state, not a failure: no reconnect loop, and a restart once the person chooses.
class SyncIdentityHold {
  SyncIdentityHold({
    required Ref ref,
    required this.wantsConnection,
    required this.isDisposed,
    required this.stop,
    required this.start,
  }) : _ref = ref;

  final Ref _ref;
  final bool Function() wantsConnection;
  final bool Function() isDisposed;
  final Future<void> Function() stop;
  final Future<void> Function() start;

  ProviderSubscription<bool>? _watch;
  bool _holding = false;

  /// Watched from the first start, not the constructor: only a sync that wants a connection has anything to stop.
  ///
  /// On the container, not the ref: the identity check reads /version behind the sync, so a ref listener would be a cycle.
  void follow() {
    _watch ??= _ref.container.listen(
      serverIdentityMismatchedProvider,
      (_, mismatched) => mismatched ? _hold() : _release(),
    );
  }

  void close() => _watch?.close();

  void _hold() {
    if (!wantsConnection()) return;
    _holding = true;
    unawaited(stop());
  }

  void _release() {
    if (!_holding) return;
    _holding = false;
    if (!isDisposed() && _ref.read(sessionProvider).isSignedIn) {
      unawaited(start());
    }
  }
}
