// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The iOS privacy wiring that only the Swift sources can break: no call in
/// Phone Recents, and a privacy cover that survives the resume.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_test_support/source_gates.dart';

String _code(String name) =>
    stripComments(File('ios/Runner/$name').readAsStringSync());

void main() {
  test('both CallKit providers keep calls out of Phone Recents', () {
    for (final name in ['VoiceCallReporter.swift', 'VoipCallHandler.swift']) {
      final code = _code(name);
      expect(
        'CXProviderConfiguration('.allMatches(code).length,
        'includesCallsInRecents = false'.allMatches(code).length,
        reason: name,
      );
    }
  });

  test('becoming active leaves the cover for Dart or the fallback to lift', () {
    final code = _code('SceneDelegate.swift');
    final start = code.indexOf('func sceneDidBecomeActive');
    final body = code.substring(
      start,
      code.indexOf('private func removeShield'),
    );
    expect(body, contains('asyncAfter'));
    expect(body.split('removeShield()').length - 1, 2);
    expect(body, isNot(contains('removeFromSuperview')));
  });
}
