// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fingerprint groups a person compares, derived here from the public key
/// that will be pinned rather than taken from the server's own display fields.
library;

import 'dart:convert';

import 'package:cryptography/dart.dart';
import 'package:slimm_api/api.dart' as api;

const _publicKeyBytes = 32;
const _fingerprintBytes = 16;
const _groupLength = 4;

/// Eight 4-character hex groups of the SHA-256 of the key, as `identity.rs`
/// derives them. Empty for a key that is not 32 base64 bytes, so a malformed
/// identity shows nothing to compare instead of a server-chosen code.
List<String> fingerprintGroupsOf(api.ServerIdentity identity) {
  final List<int> key;
  try {
    key = base64.decode(identity.publicKey);
  } on FormatException {
    return const [];
  }
  if (key.length != _publicKeyBytes) return const [];
  final digest = const DartSha256().hashSync(key).bytes;
  final hex = [
    for (final b in digest.take(_fingerprintBytes))
      b.toRadixString(16).padLeft(2, '0'),
  ].join();
  return [
    for (var i = 0; i < hex.length; i += _groupLength)
      hex.substring(i, i + _groupLength),
  ];
}
