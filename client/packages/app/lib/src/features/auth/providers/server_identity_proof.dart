// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading a server's identity and asking it to prove it holds the key
/// (decision 0036): a copied public key alone no longer passes for the server.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart' show KeyStore;

/// How a server answered `/version` and the identity challenge.
enum IdentityAnswer {
  /// Nothing came back from one of the two requests.
  unanswered,

  /// It answered, but not with a slim-m `/version`.
  notSlim,

  /// It said it is busy (429 or 503), which says nothing about its key.
  busy,

  /// A slim-m server that gave no valid proof, as one older than the challenge does.
  unproven,

  /// It signed the challenge with the key it reports.
  proven,

  /// It answered the challenge with a signature its key does not verify.
  disproven,
}

/// What a server said about its identity, and how far it proved it.
typedef IdentityReading = ({
  IdentityAnswer answer,
  api.ServerIdentity? identity,
});

/// Whether [error] came from a server that answered, not from one nothing came back from.
bool serverAnswered(Object error) =>
    error is! api.TransportException || error is api.UnreadableReplyException;

/// Whether [error] is a server saying it is busy, which says nothing about its key.
///
/// An ambient recheck of a signed-in session reads it as no verdict; a caller about to send a secret asks again first.
bool serverBusy(Object error) =>
    error is api.RateLimitedException || error is api.UnavailableException;

/// Asks [client] to sign a fresh challenge and checks it against [identity]'s key.
Future<IdentityAnswer> challengeIdentity(
  api.SlimmApi client,
  api.ServerIdentity identity,
) async {
  final random = Random.secure();
  final challenge = Uint8List.fromList(
    List.generate(32, (_) => random.nextInt(256)),
  );
  final api.IdentityProof proof;
  try {
    proof = await client.proveIdentity(challenge);
  } catch (error, stack) {
    api.reportFailure(
      api.LogTag.auth,
      'prove the server identity',
      error,
      stack,
    );
    if (serverBusy(error)) return IdentityAnswer.busy;
    return serverAnswered(error)
        ? IdentityAnswer.unproven
        : IdentityAnswer.unanswered;
  }
  if (proof.publicKey != identity.publicKey) return IdentityAnswer.disproven;
  return await verifyIdentityProof(
        identity.publicKey,
        challenge,
        proof.signature,
      )
      ? IdentityAnswer.proven
      : IdentityAnswer.disproven;
}

/// Whether [signature] is [publicKey]'s Ed25519 signature over the proof context and [challenge].
Future<bool> verifyIdentityProof(
  String publicKey,
  List<int> challenge,
  String signature,
) async {
  final List<int> key;
  final List<int> signed;
  try {
    key = base64.decode(publicKey);
    signed = base64.decode(signature);
  } on FormatException {
    return false;
  }
  if (key.length != 32 || signed.length != 64) return false;
  return Ed25519().verify(
    [...api.identityProofContext, ...challenge],
    signature: Signature(
      signed,
      publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
    ),
  );
}

/// The handle the last key an address proved is stored under, beside its pin.
String identityProofHandleFor(Uri address) =>
    'server_identity_proved:${address.origin}';

/// Whether [reading] holds up [pinned] for [server]: proven, or unproven by a
/// server that has never proven that key, as an older one never has.
///
/// A proof is remembered, so the same address later skipping it counts against it.
Future<bool> holdsPinnedKey(
  KeyStore keyStore,
  Uri server,
  String pinned,
  IdentityReading reading,
) async {
  if (reading.identity?.publicKey != pinned) return false;
  final handle = identityProofHandleFor(server);
  switch (reading.answer) {
    case IdentityAnswer.proven:
      await keyStore.put(handle, pinned);
      return true;
    case IdentityAnswer.unproven:
      return await keyStore.read(handle) != pinned;
    case IdentityAnswer.unanswered ||
        IdentityAnswer.busy ||
        IdentityAnswer.notSlim ||
        IdentityAnswer.disproven:
      return false;
  }
}
