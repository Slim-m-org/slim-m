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
import 'providers.dart';
import 'sync_controller.dart';

/// The identity the server now presents when it differs from the pinned one.
///
/// Null for every case that is not a proven mismatch: signed out, nothing
/// pinned yet, an unreachable server, or one too old to report a key. Failing
/// open here matches sign-in, which treats an unreadable probe as unknown.
/// A mismatch already proven is the exception: a failed re-probe keeps it,
/// because an unreadable answer is no verdict and must not retract one.
final serverIdentityChangeProvider =
    AsyncNotifierProvider<ServerIdentityChange, api.ServerIdentity?>(
      ServerIdentityChange.new,
    );

class ServerIdentityChange extends AsyncNotifier<api.ServerIdentity?> {
  @override
  Future<api.ServerIdentity?> build() async {
    final proven = state.valueOrNull;
    ref.watch(syncControllerProvider);
    if (!ref.watch(sessionProvider).isSignedIn) return null;

    final server = ref.watch(serverUrlProvider);
    final pinned = await ref
        .watch(keyStoreProvider)
        .read(identityHandleFor(server));
    if (pinned == null) return null;

    try {
      final identity = (await ref.watch(apiProvider).version()).identity;
      if (identity == null || identity.publicKey == pinned) return null;
      return identity;
    } catch (_) {
      return proven?.publicKey == pinned ? null : proven;
    }
  }
}
