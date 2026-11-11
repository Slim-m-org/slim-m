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
///
/// [requireSlimServer] makes an address that answers without a slim-m
/// `/version` throw [api.NotASlimServerException] instead of counting as unknown.
Future<bool> confirmServerIdentity(
  BuildContext context,
  WidgetRef ref,
  Uri server, {
  bool requireSlimServer = false,
}) async {
  final client = ref.read(probeApiProvider)(server);
  api.ServerIdentity? identity;
  try {
    identity = (await client.version()).identity;
  } on api.NotASlimServerException {
    if (requireSlimServer) rethrow;
    return true;
  } catch (error, stack) {
    api.reportFailure(
      api.LogTag.auth,
      'confirm the server identity',
      error,
      stack,
    );
    return true;
  } finally {
    client.close();
  }
  if (!context.mounted) return false;

  final keyStore = ref.read(keyStoreProvider);
  final handle = identityHandleFor(server);
  final pinned = await keyStore.read(handle);

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
