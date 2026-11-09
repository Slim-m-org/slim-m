// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the server a signed-in session points at still presents the key
/// pinned for it (decision 0036).
///
/// `restoreSession` is network-free, so a relaunch never went through
/// `confirmServerIdentity`. This asks again on launch and on every reconnect,
/// and only ever answers with an identity that contradicts a pin.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../widgets/server_identity_confirmation.dart';
import '../../../providers/providers.dart';
import 'server_version_probe.dart';

/// What a pinned server presents instead of its pinned key.
class IdentityMismatch {
  const IdentityMismatch(this.presented);

  /// The key now presented; null when the server reports no identity at all.
  final api.ServerIdentity? presented;
}

/// The mismatch the server now presents against the pinned identity.
///
/// Null for every case that is not a proven mismatch: signed out, nothing
/// pinned yet, or an unreachable server. Failing open here matches sign-in,
/// which treats an unreadable probe as unknown. A pinned server that reports
/// no identity is a mismatch, not an old server: the real server always
/// reports one. A mismatch already proven is the exception to failing open: a
/// failed re-probe keeps it, because an unreadable answer is no verdict and
/// must not retract one.
final serverIdentityChangeProvider =
    AsyncNotifierProvider<ServerIdentityChange, IdentityMismatch?>(
      ServerIdentityChange.new,
    );

class ServerIdentityChange extends AsyncNotifier<IdentityMismatch?> {
  bool _missingAccepted = false;

  /// Carries on without an identity for the rest of this run, keeping the pin.
  void acceptMissingIdentity() {
    _missingAccepted = true;
    ref.invalidateSelf();
  }

  @override
  Future<IdentityMismatch?> build() async {
    final proven = state.valueOrNull;
    if (!ref.watch(sessionProvider).isSignedIn) return null;

    final server = ref.watch(serverUrlProvider);
    final pinned = await ref
        .watch(keyStoreProvider)
        .read(identityHandleFor(server));
    if (pinned == null) return null;

    final version = await ref.watch(serverVersionProbeProvider.future);
    if (version == null) {
      return proven?.presented?.publicKey == pinned ? null : proven;
    }
    final identity = version.identity;
    if (identity == null) {
      return _missingAccepted ? null : const IdentityMismatch(null);
    }
    if (identity.publicKey == pinned) return null;
    return IdentityMismatch(identity);
  }
}
