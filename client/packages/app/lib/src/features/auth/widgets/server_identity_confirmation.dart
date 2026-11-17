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

import '../../../providers/providers.dart';
import '../../../routing/page_transitions.dart';
import 'server_identity_changed_step.dart';

/// The handle a server's pinned public key is stored under, one per address:
/// a session token is per-account, but this is a property of the address
/// itself and must survive across every account ever signed into it.
String identityHandleFor(Uri address) => 'server_identity:${address.origin}';

/// Identity handles of the addresses first met during this run, so the
/// sign-in that follows does not treat a key saved a moment ago as known.
final firstContactServersProvider = StateProvider<Set<String>>(
  (ref) => const {},
);

/// What `/version` said about a server's identity, read before deciding
/// anything: [known] is false when it could not answer as a slim-m server.
typedef ServerIdentityProbe = ({bool known, api.ServerIdentity? identity});

/// Reads [server]'s identity without pinning or navigating, so a dialog can
/// show it is waiting and close before [settleServerIdentity] runs.
///
/// [requireSlimServer] makes an address that answers without a slim-m
/// `/version` throw [api.NotASlimServerException] instead of counting as unknown.
Future<ServerIdentityProbe> probeServerIdentity(
  WidgetRef ref,
  Uri server, {
  bool requireSlimServer = false,
}) async {
  final client = ref.read(probeApiProvider)(server);
  try {
    return (known: true, identity: (await client.version()).identity);
  } on api.NotASlimServerException {
    if (requireSlimServer) rethrow;
    return (known: false, identity: null);
  } catch (error, stack) {
    api.reportFailure(
      api.LogTag.auth,
      'confirm the server identity',
      error,
      stack,
    );
    return (known: false, identity: null);
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
/// A server that reports no identity is unknown only while nothing is pinned
/// for it; once a key is pinned, leaving the identity out is a change, and goes
/// through the same warning as a different key.
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
  if (!probe.known) return true;
  final identity = probe.identity;

  if (identity == null && pinned == null) return true;
  if (pinned != null && pinned == identity?.publicKey) return true;
  if (!context.mounted) return false;

  if (pinned == null) {
    await keyStore.put(handle, identity!.publicKey);
    return true;
  }

  final trusted = await Navigator.of(context).push<bool>(
    fadeThroughRoute<bool>(
      context,
      (context) =>
          ServerIdentityChangedStep(address: server, identity: identity),
    ),
  );

  if (trusted != true) return false;
  // Nothing to pin when the server reported nothing; the old key stays pinned.
  if (identity != null) await keyStore.put(handle, identity.publicKey);
  return true;
}
