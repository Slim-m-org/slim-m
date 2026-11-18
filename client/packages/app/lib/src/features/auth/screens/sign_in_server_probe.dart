// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading the sign-in screen's server field without side effects.
library;

import 'package:slimm_api/api.dart';
import 'package:slimm_platform/platform.dart' show KeyStore;

import '../../../server_address_input.dart';
import '../../../server_address_reduction.dart';
import '../../../server_scheme_policy.dart';
import '../providers/browser_reach.dart';
import '../widgets/server_identity_chip.dart';
import '../widgets/server_identity_confirmation.dart';
import '../widgets/sign_in_error.dart';

/// Reduces a typed address to the scheme, host, and port worth probing.
/// Anything else it carries (path, query, userinfo) must not ride along
/// on a request that fires as someone types: pasted userinfo would even
/// become a Basic auth header sent to whatever host is in the field.
Uri? probeTarget(String text) {
  final parsed = parseServerAddress(text);
  return parsed == null ? null : reduceServerAddress(parsed);
}

/// [text] as an address sign-in may send to, or why it may not be: one
/// wording for every door onto the field (sign-in, recovery, the join steps).
(Uri?, String?) submittableAddress(String text) {
  final address = parseServerAddress(text);
  if (address == null) return (null, serverAddressError(text));
  if (requireSecureScheme(address) case final problem?) return (null, problem);
  return (address, null);
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
  final host = parseServerAddress(text)?.host ?? '';
  return host.isEmpty ? text.trim() : host;
}

/// What `/version` at a server said, or why it could not say: [failure] is
/// worded for the server field, and both are null for no address at all.
typedef ServerProbe = ({Version? version, String? failure});

/// Asks [client]'s server what it is, and closes [client].
///
/// A host that answers with something that is not a slim-m `/version` is as
/// unknown as one that refuses to connect, so the bare `catch` is deliberate:
/// a foreign or hostile server must not crash sign-in with a shaped reply.
Future<ServerProbe> probeServerVersion(
  SlimmApi client,
  Uri target, {
  required BrowserReachProbe reach,
  required Future<bool> Function(Uri server) knownSpace,
}) async {
  try {
    return (version: await client.version(), failure: null);
  } on ApiException catch (error, stack) {
    reportFailure(LogTag.auth, 'check the server address', error, stack);
    final (_, failure) = await explainSignInFailure(
      error,
      server: target,
      reach: reach,
      knownSpace: knownSpace,
    );
    return (version: null, failure: failure);
  } catch (error, stack) {
    reportFailure(LogTag.auth, 'check the server address', error, stack);
    return (version: null, failure: notASlimServerError.$2);
  } finally {
    client.close();
  }
}

/// What the form shows about an address: what it said or why it could not,
/// and how its key compares with a pinned one.
typedef ServerAnswer = ({
  Version? version,
  String? failure,
  ServerIdentityStatus? status,
});

/// Asks the server in [text] what it is. An address the form would refuse to
/// submit to is not asked at all, and the refusal is the failure.
Future<ServerAnswer> answerForAddress(
  String text, {
  required SlimmApi Function(Uri) probeApi,
  required KeyStore keyStore,
  required BrowserReachProbe reach,
}) async {
  final (address, problem) = submittableAddress(text);
  if (address == null) return (version: null, failure: problem, status: null);
  final target = reduceServerAddress(address);
  final probe = await probeServerVersion(
    probeApi(target),
    target,
    reach: reach,
    knownSpace: pinnedIdentityCheck(keyStore),
  );
  final version = probe.version;
  final status = await identityStatusFor(keyStore, target, version?.identity);
  return (version: version, failure: probe.failure, status: status);
}
