// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:convert';

import 'package:cryptography/dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/server_fingerprint_step.dart';
import 'package:slimm_design_system/design_system.dart';

List<String> _groupsFor(String publicKeyB64) {
  final hex = const DartSha256()
      .hashSync(base64.decode(publicKeyB64))
      .bytes
      .take(16)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return [for (var i = 0; i < 32; i += 4) hex.substring(i, i + 4)];
}

void main() {
  testWidgets('the shown groups come from the key that will be pinned', (
    tester,
  ) async {
    final realKey = base64.encode(List<int>.filled(32, 1));
    final attackerKey = base64.encode(List<int>.filled(32, 2));
    // A hostile server pins its own key but sends the real server's groups.
    final identity = api.ServerIdentity(
      publicKey: attackerKey,
      fingerprint: _groupsFor(realKey).join(),
      fingerprintGroups: _groupsFor(realKey),
      colorStrip: const [0, 1, 2, 3],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: FingerprintDisplay(identity: identity)),
      ),
    );
    final g = _groupsFor(attackerKey);
    expect(find.text(g.take(4).join('  ')), findsOneWidget);
  });
}
