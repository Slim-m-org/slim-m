// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The orchestration behind confirming a server's identity: probing
/// `/version`, comparing against whatever this app already pinned for that
/// address, and deciding whether a human needs to see the changed-key warning
/// before a connection may proceed.
///
/// Shared by every entry point that commits to a server address - sign-in,
/// the invite dialog, the manual dialog, and the official-server button -
/// so the same pin is read and written no matter which door someone used.
///
/// A relaunch of a signed-in session never reaches this: `restoreSession` is
/// network-free, so `ServerIdentityChangeGate` re-probes it instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart' show KeyStore;

import '../../../providers/providers.dart';
import '../../../routing/page_transitions.dart';
import '../providers/server_identity_proof.dart';
import 'server_identity_changed_step.dart';

/// The handle a server's pinned public key is stored under, one per address:
/// a session token is per-account, but this is a property of the address
/// itself and must survive across every account ever signed into it.
String identityHandleFor(Uri address) => 'server_identity:${address.origin}';

/// Whether a slim-m server at an address has had its identity pinned in
/// [keyStore]; a store that cannot be read knows of none.
Future<bool> Function(Uri server) pinnedIdentityCheck(KeyStore keyStore) =>
    (server) async {
      try {
        return await keyStore.read(identityHandleFor(server)) != null;
      } catch (error, stack) {
        api.reportFailure(api.LogTag.auth, 'read a pinned key', error, stack);
        return false;
      }
    };

/// Identity handles of the addresses first met during this run, so the
/// sign-in that follows does not treat a key saved a moment ago as known.
final firstContactServersProvider = StateProvider<Set<String>>(
  (ref) => const {},
);

/// Ends [server]'s first contact once a sign-in to it succeeds, so the next
/// visit in this run is a return to a Space whose key is now known.
void endFirstContact(StateController<Set<String>> firstContact, Uri server) {
  final handle = identityHandleFor(server);
  firstContact.update((handles) => {...handles}..remove(handle));
}

/// What `/version` and the identity challenge said, read before deciding anything.
typedef ServerIdentityProbe = IdentityReading;

/// Reads [server]'s identity without pinning or navigating, so a dialog can
/// show it is waiting and close before [settleServerIdentity] runs.
///
/// [requireSlimServer] is for a caller about to send a password: an address
/// that answers without a slim-m `/version` throws
/// [api.NotASlimServerException], and a pinned one nothing comes back from
/// rethrows that failure instead of counting as unknown.
Future<ServerIdentityProbe> probeServerIdentity(
  WidgetRef ref,
  Uri server, {
  bool requireSlimServer = false,
}) async {
  final keyStore = ref.read(keyStoreProvider);
  final client = ref.read(probeApiProvider)(server);
  try {
    final api.Version version;
    try {
      version = await client.version();
    } on api.NotASlimServerException {
      if (requireSlimServer) rethrow;
      return (answer: IdentityAnswer.notSlim, identity: null);
    } catch (error, stack) {
      api.reportFailure(
        api.LogTag.auth,
        'confirm the server identity',
        error,
        stack,
      );
      if (serverAnswered(error)) {
        return (answer: IdentityAnswer.notSlim, identity: null);
      }
      if (requireSlimServer && await pinnedIdentityCheck(keyStore)(server)) {
        rethrow;
      }
      return (answer: IdentityAnswer.unanswered, identity: null);
    }
    final identity = version.identity;
    if (identity == null) {
      return (answer: IdentityAnswer.unproven, identity: null);
    }
    final answer = await challengeIdentity(client, identity);
    if (answer == IdentityAnswer.unanswered &&
        requireSlimServer &&
        await pinnedIdentityCheck(keyStore)(server)) {
      throw const api.TransportException(
        'the server did not answer the identity challenge',
      );
    }
    return (answer: answer, identity: identity);
  } finally {
    client.close();
  }
}

/// Probes the chosen address's identity and pins it, trust-on-first-use
/// style: the first key seen is pinned silently, a match is silent, and a
/// changed key is a hard stop with a full-screen warning.
///
/// Returns whether it is safe to continue with [server]. An unreachable one is
/// treated as unknown rather than blocked: sign-in surfaces a real connection
/// failure with more authority than a probe run during onboarding ever could.
/// A server that answers without a slim-m `/version`, reports no identity, or
/// cannot prove it holds its key is unknown only while nothing is pinned for
/// it; once a key is pinned, each of those is a change, and goes through the
/// same warning as a different key.
Future<bool> confirmServerIdentity(
  BuildContext context,
  WidgetRef ref,
  Uri server, {
  bool requireSlimServer = false,
}) async {
  final probe = await probeServerIdentity(
    ref,
    server,
    requireSlimServer: requireSlimServer,
  );
  if (!context.mounted) return false;
  return settleServerIdentity(context, ref, server, probe);
}

/// The pin half of [confirmServerIdentity], for a [probe] already read.
Future<bool> settleServerIdentity(
  BuildContext context,
  WidgetRef ref,
  Uri server,
  ServerIdentityProbe probe,
) async {
  final keyStore = ref.read(keyStoreProvider);
  final handle = identityHandleFor(server);
  final pinned = await keyStore.read(handle);
  if (pinned == null) {
    ref
        .read(firstContactServersProvider.notifier)
        .update((handles) => {...handles, handle});
  }
  if (probe.answer == IdentityAnswer.unanswered) return true;
  final identity = probe.identity;

  if (pinned == null) {
    if (identity == null || probe.answer == IdentityAnswer.disproven) {
      return true;
    }
    await keyStore.put(handle, identity.publicKey);
    if (probe.answer == IdentityAnswer.proven) {
      await keyStore.put(identityProofHandleFor(server), identity.publicKey);
    }
    return true;
  }
  if (await holdsPinnedKey(keyStore, server, pinned, probe)) return true;
  if (!context.mounted) return false;
  final presented =
      identity?.publicKey == pinned || probe.answer == IdentityAnswer.disproven
      ? null
      : identity;

  final trusted = await Navigator.of(context).push<bool>(
    fadeThroughRoute<bool>(
      context,
      (context) =>
          ServerIdentityChangedStep(address: server, identity: presented),
    ),
  );

  if (trusted != true) return false;
  // Nothing new to pin when the server proved nothing; the old key stays pinned.
  if (presented != null) await keyStore.put(handle, presented.publicKey);
  return true;
}
