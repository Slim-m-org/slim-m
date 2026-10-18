// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The orchestration behind confirming a server's identity: probing
/// `/version`, comparing against whatever this app already pinned for that
/// address, and deciding which of the two identity screens (if either) a
/// human needs to see before a connection may proceed.
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
import '../../../widgets/server_fingerprint_step.dart';
import 'server_identity_changed_step.dart';

/// The handle a server's pinned public key is stored under, one per address:
/// a session token is per-account, but this is a property of the address
/// itself and must survive across every account ever signed into it.
String identityHandleFor(Uri address) => 'server_identity:${address.origin}';

/// Probes the chosen address's identity and pins it, trust-on-first-use
/// style: silent when it matches what is already pinned, an explicit step
/// the first time there is nothing to compare against, and a hard stop that
/// needs deliberate acknowledgement if it ever changes.
///
/// Returns whether it is safe to continue with [server]. A server too old to
/// report an identity, or unreachable here, is treated as unknown rather than
/// blocked: sign-in surfaces a real connection failure with more authority
/// than a probe run during onboarding ever could.
///
/// [silentFirstConnect] skips the fingerprint screen on a first connect and
/// pins whatever answered without asking - only correct for an address
/// nobody typed, such as the compiled-in official server, where there is no
/// out-of-band admin to compare the code with. A key that later changes is
/// never silent, with or without this flag: that is the one case
/// trust-on-first-use exists to make visible.
Future<bool> confirmServerIdentity(
  BuildContext context,
  WidgetRef ref,
  Uri server, {
  bool silentFirstConnect = false,
}) async {
  final client = ref.read(probeApiProvider)(server);
  api.ServerIdentity? identity;
  try {
    identity = (await client.version()).identity;
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
  if (identity == null) return true;
  if (!context.mounted) return false;

  final keyStore = ref.read(keyStoreProvider);
  final handle = identityHandleFor(server);
  final pinned = await keyStore.read(handle);

  if (pinned == identity.publicKey) return true;
  if (!context.mounted) return false;

  if (pinned == null && silentFirstConnect) {
    await keyStore.put(handle, identity.publicKey);
    return true;
  }

  final trusted = pinned == null
      ? await Navigator.of(context).push<bool>(
          fadeThroughRoute<bool>(
            context,
            (context) =>
                ServerFingerprintStep(address: server, identity: identity!),
          ),
        )
      : await Navigator.of(context).push<bool>(
          fadeThroughRoute<bool>(
            context,
            (context) =>
                ServerIdentityChangedStep(address: server, identity: identity!),
          ),
        );

  if (trusted != true) return false;
  await keyStore.put(handle, identity.publicKey);
  return true;
}
