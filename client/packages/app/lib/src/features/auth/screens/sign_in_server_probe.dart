// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading the sign-in screen's server field without side effects.
library;

import 'package:slimm_api/api.dart';
import 'package:slimm_platform/platform.dart' show KeyStore;

import '../../../server_address_reduction.dart';
import '../widgets/server_identity_chip.dart';
import '../widgets/server_identity_confirmation.dart';

/// Reduces a typed address to the scheme, host, and port worth probing.
/// Anything else it carries (path, query, userinfo) must not ride along
/// on a request that fires as someone types: pasted userinfo would even
/// become a Basic auth header sent to whatever host is in the field.
Uri? probeTarget(String text) {
  final parsed = Uri.tryParse(text.trim());
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
    return null;
  }
  return reduceServerAddress(parsed);
}

/// How [identity] compares against whatever is pinned for [target], for
/// the passive chip only: read-only, no pinning and no navigation. The
/// active check that pins and can block a connection is
/// [confirmServerIdentity].
Future<ServerIdentityStatus> identityStatusFor(
  KeyStore keyStore,
  Uri target,
  ServerIdentity? identity,
) async {
  final pinned = await keyStore.read(identityHandleFor(target));
  if (pinned == null) return ServerIdentityStatus.unknown;
  // A pinned address that reports no identity is a change, not an old server.
  return pinned == identity?.publicKey
      ? ServerIdentityStatus.confirmed
      : ServerIdentityStatus.mismatch;
}

/// The host in [text], for naming the destination on screen. Falls back
/// to the raw text so a half-typed address still shows what it is rather
/// than going blank mid-keystroke.
String serverHostLabel(String text) {
  final host = Uri.tryParse(text.trim())?.host ?? '';
  return host.isEmpty ? text.trim() : host;
}
