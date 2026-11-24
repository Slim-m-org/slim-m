// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `POST /identity/proof`: the server's signature over a challenge this client chose.
library;

import 'dart:convert';

import 'client.dart';
import 'client_transport.dart';
import 'exceptions.dart' show NotFoundException, UnreadableReplyException;

/// What a server returned for an identity challenge, still unverified.
class IdentityProof {
  const IdentityProof({required this.publicKey, required this.signature});

  /// Standard base64 of the key the server says it signed with.
  final String publicKey;

  /// Standard base64 of the Ed25519 signature over [identityProofContext] and the challenge.
  final String signature;

  factory IdentityProof.fromJson(Map<String, dynamic> json) => IdentityProof(
        publicKey: json['public_key'] as String,
        signature: json['signature'] as String,
      );
}

/// The bytes the server signs ahead of the challenge; the server's `PROOF_CONTEXT`.
final identityProofContext = utf8.encode('slim-m identity proof v1\n');

extension SlimmApiIdentityProof on SlimmApi {
  /// Asks the server to sign [challenge]. A server older than the route
  /// answers 404, which surfaces as a [NotFoundException]; a reply of the
  /// wrong shape is an [UnreadableReplyException], so it reads as answered.
  Future<IdentityProof> proveIdentity(List<int> challenge) async {
    final json = await send(
      'POST',
      '/identity/proof',
      body: {'challenge': base64.encode(challenge)},
      authenticated: false,
    );
    try {
      return IdentityProof.fromJson(json as Map<String, dynamic>);
    } on TypeError catch (e) {
      throw UnreadableReplyException(
          'unexpected reply to an identity proof: $e');
    }
  }
}
