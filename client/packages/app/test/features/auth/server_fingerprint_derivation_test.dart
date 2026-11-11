// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The five words come from the key that will be pinned, and match the vector
/// `identity.rs` asserts too.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/auth/widgets/server_identity_changed_step.dart';
import 'package:slimm_app/src/features/auth/widgets/server_identity_fingerprint.dart';
import 'package:slimm_app/src/features/auth/widgets/server_identity_words.dart';
import 'package:slimm_design_system/design_system.dart';

api.ServerIdentity _identity(List<int> key) => api.ServerIdentity(
  publicKey: base64.encode(key),
  fingerprint: '',
  fingerprintGroups: const [],
  colorStrip: const [0, 1, 2, 3],
);

void main() {
  test('the wordlist is the 2048-word BIP39 list', () {
    expect(bip39Words.length, 2048);
    expect(bip39Words.first, 'abandon');
    expect(bip39Words.last, 'zoo');
  });

  test('the words match the shared vector', () {
    expect(fingerprintWordsOf(_identity(List<int>.generate(32, (i) => i))), [
      'glide',
      'hover',
      'engage',
      'snow',
      'drip',
    ]);
    expect(fingerprintWordsOf(_identity(List<int>.filled(32, 7))), [
      'entry',
      'lock',
      'toe',
      'organ',
      'polar',
    ]);
  });

  test('a key that is not 32 bytes yields no words', () {
    expect(fingerprintWordsOf(_identity(List<int>.filled(31, 7))), isEmpty);
  });

  testWidgets('the screen shows the words derived from the key', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: ServerIdentityChangedStep(
          address: Uri.parse('https://chat.example'),
          identity: _identity(List<int>.filled(32, 7)),
        ),
      ),
    );
    for (final word in ['entry', 'lock', 'toe', 'organ', 'polar']) {
      expect(find.text(word), findsOneWidget);
    }
  });
}
