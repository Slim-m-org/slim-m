// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The changed-key warning is blunt: a headline, one sentence, five words and
/// two actions, with nothing to copy and nothing to squint at.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/auth/widgets/server_identity_changed_step.dart';
import 'package:slimm_design_system/design_system.dart';

const _headline = "This isn't the server you joined before";

Future<List<bool>> _pump(
  WidgetTester tester, {
  required api.ServerIdentity? identity,
}) async {
  final decisions = <bool>[];
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: ServerIdentityChangedStep(
        address: Uri.parse('https://chat.example'),
        identity: identity,
        onDecision: decisions.add,
      ),
    ),
  );
  return decisions;
}

api.ServerIdentity get _identity => api.ServerIdentity(
  publicKey: base64.encode(List<int>.filled(32, 7)),
  fingerprint: '',
  fingerprintGroups: const [],
  colorStrip: const [0, 1, 2, 3],
);

void main() {
  testWidgets('shows the headline, the five words in order, and both actions '
      'without scrolling on a phone', (tester) async {
    await _pump(tester, identity: _identity);

    expect(find.text(_headline), findsOneWidget);
    final tops = [
      for (final w in ['entry', 'lock', 'toe', 'organ', 'polar'])
        tester.getTopLeft(find.text(w)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    final screen = tester.view.physicalSize.height;
    final trust = tester.getBottomLeft(find.text('Trust the new server')).dy;
    final back = tester.getTopLeft(find.text('Go back')).dy;
    expect(trust, lessThan(screen));
    expect(back, lessThan(trust), reason: 'the safe action comes first');
    expect(find.text('Copy this code'), findsNothing);
  });

  testWidgets('both actions report the decision at once', (tester) async {
    final decisions = await _pump(tester, identity: _identity);

    await tester.tap(find.text('Go back'));
    await tester.tap(find.text('Trust the new server'));

    expect(decisions, [false, true]);
  });

  testWidgets('a server that presents no identity shows no words', (
    tester,
  ) async {
    await _pump(tester, identity: null);

    expect(find.text(_headline), findsOneWidget);
    expect(find.text('Trust the new server'), findsOneWidget);
    expect(find.text('entry'), findsNothing);
  });
}
