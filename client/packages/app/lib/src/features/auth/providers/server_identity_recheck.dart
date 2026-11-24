// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the server a signed-in session points at still presents the key
/// pinned for it (decision 0036).
///
/// `restoreSession` is network-free, so a relaunch never went through
/// `confirmServerIdentity`. This asks again on launch and on every reconnect,
/// and only ever answers with an identity that contradicts a pin.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../widgets/server_identity_confirmation.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';
import 'server_identity_proof.dart';
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
/// pinned yet, or a server nothing comes back from. Failing open there is
/// decision 0036's choice for an unreachable server. A pinned server that
/// answers without a slim-m `/version`, reports no identity, or cannot prove
/// it holds the pinned key is a mismatch, not an old server: the real one
/// answers and proves (an older one that has never proven is the exception).
/// A mismatch already proven survives a re-probe nothing came back from,
/// because no answer is no verdict and must not retract one.
final serverIdentityChangeProvider =
    AsyncNotifierProvider<ServerIdentityChange, IdentityMismatch?>(
      ServerIdentityChange.new,
    );

/// Bumped when a plain-http connection drops, so the gate holds the next call
/// that carries the session until the server has answered again.
final identityRecheckEpochProvider = StateProvider<int>((ref) => 0);

class ServerIdentityChange extends AsyncNotifier<IdentityMismatch?> {
  bool _missingAccepted = false;

  /// Carries on without an identity for the rest of this run, keeping the pin.
  void acceptMissingIdentity() {
    _missingAccepted = true;
    ref.invalidateSelf();
  }

  /// Pins [presented] as this server's key, so the session may reach it again.
  Future<void> trust(api.ServerIdentity presented) async {
    final server = ref.read(serverUrlProvider);
    await ref
        .read(keyStoreProvider)
        .put(identityHandleFor(server), presented.publicKey);
    ref.invalidateSelf();
  }

  /// Asks again the moment the sync is live, without waiting to be read: a
  /// window in the tray draws no frame, and nothing else would refresh this.
  /// A plain-http server is also asked again as soon as its connection drops,
  /// since a changed network can put another host at the same address.
  void _recheckOnReconnect(Uri server) {
    var current = true;
    ref.onDispose(() => current = false);
    ref.listen(syncControllerProvider, (previous, next) {
      if (previous == SyncStatus.live &&
          next != SyncStatus.live &&
          !server.isScheme('https')) {
        ref.read(identityRecheckEpochProvider.notifier).state++;
        ref.invalidate(serverVersionReadProvider);
        return;
      }
      if (next != SyncStatus.live || previous == SyncStatus.live) return;
      // After the probe's own listener has marked it stale, whichever of the two runs first.
      scheduleMicrotask(() {
        if (current) future.ignore();
      });
    });
  }

  IdentityMismatch? get _missing =>
      _missingAccepted ? null : const IdentityMismatch(null);

  @override
  Future<IdentityMismatch?> build() async {
    final proven = state.valueOrNull;
    IdentityMismatch? unanswered(String pinned) =>
        proven?.presented?.publicKey == pinned ? null : proven;
    if (!ref.watch(sessionProvider).isSignedIn) return null;

    final server = ref.watch(serverUrlProvider);
    final keyStore = ref.watch(keyStoreProvider);
    final pinned = await keyStore.read(identityHandleFor(server));
    if (pinned == null) return null;

    _recheckOnReconnect(server);
    final read = await ref.watch(serverVersionReadProvider.future);
    final version = read.version;
    if (version == null) return read.answered ? _missing : unanswered(pinned);
    final identity = version.identity;
    if (identity == null) return _missing;
    if (identity.publicKey != pinned) return IdentityMismatch(identity);

    final answer = await challengeIdentity(ref.read(apiProvider), identity);
    if (answer == IdentityAnswer.unanswered) return unanswered(pinned);
    final reading = (answer: answer, identity: identity);
    return await holdsPinnedKey(keyStore, server, pinned, reading)
        ? null
        : _missing;
  }
}
