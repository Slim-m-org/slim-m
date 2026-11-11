// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The five words a person checks with the admin, derived here from the public
/// key that will be pinned rather than taken from the server's own display
/// fields.
library;

import 'dart:convert';

import 'package:cryptography/dart.dart';
import 'package:slimm_api/api.dart' as api;

import 'server_identity_words.dart';

const _publicKeyBytes = 32;
const _wordCount = 5;
const _wordBits = 11;

/// The first 55 bits of the SHA-256 of the key, 11 bits per BIP39 word, as
/// `identity.rs` derives them. Empty for a key that is not 32 base64 bytes, so
/// a malformed identity shows nothing to compare instead of a server-chosen
/// code.
List<String> fingerprintWordsOf(api.ServerIdentity identity) {
  final List<int> key;
  try {
    key = base64.decode(identity.publicKey);
  } on FormatException catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.auth,
      'The server identity key is not valid base64',
      error,
      stack,
    );
    return const [];
  }
  if (key.length != _publicKeyBytes) return const [];
  final hash = const DartSha256().hashSync(key).bytes;
  return [
    for (var word = 0; word < _wordCount; word++)
      bip39Words[_bitsAt(hash, word * _wordBits)],
  ];
}

int _bitsAt(List<int> bytes, int firstBit) {
  var value = 0;
  for (var bit = firstBit; bit < firstBit + _wordBits; bit++) {
    value = (value << 1) | ((bytes[bit ~/ 8] >> (7 - bit % 8)) & 1);
  }
  return value;
}
