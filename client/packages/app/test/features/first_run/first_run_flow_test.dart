// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The setup flow end to end through the gate: each step's save call, the
/// landing channel, skipping, and the empty pane's guidance.
library;

import 'dart:convert';

import 'dart:ui' show Size;

import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart' show EditableText;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart' show AppInput;

import 'package:slimm_app/src/features/first_run/widgets/first_run_frame.dart';

import 'first_run_harness.dart';

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await settle(tester);
}

void main() {
  testWidgets('a new account sees the welcome step with the Space', (
    tester,
  ) async {
    await pumpFirstRun(tester, inviter: 'Grace');
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('Lamplight'), findsOneWidget);
    expect(find.textContaining('game night'), findsOneWidget);
    expect(find.text('Grace invited you.'), findsOneWidget);
    expect(find.text('Skip setup'), findsOneWidget);
  });

  testWidgets('a returning account never sees it', (tester) async {
    await pumpFirstRun(tester, accountAge: const Duration(days: 4));
    expect(find.text('Skip setup'), findsNothing);
    expect(find.text('shell'), findsOneWidget);
  });

  testWidgets('skip setup closes it for good and stays put', (tester) async {
    await pumpFirstRun(tester);
    await _tap(tester, 'Skip setup');
    expect(find.text('Skip setup'), findsNothing);
    expect(find.text('shell'), findsOneWidget);
  });

  testWidgets('the you step saves pronouns on continue', (tester) async {
    final rig = await pumpFirstRun(tester);
    await _tap(tester, 'Continue');
    expect(find.text('Set up your profile'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(AppInput),
        matching: find.byType(EditableText),
      ),
      'she/her',
    );
    await _tap(tester, 'Continue');

    final patch = rig.sent('PATCH', '/me');
    expect(patch, hasLength(1));
    expect(jsonDecode(patch.first.body), {'pronouns': 'she/her'});
    expect(find.text('Choose your notifications'), findsOneWidget);
  });

  testWidgets('an untouched you step sends nothing', (tester) async {
    final rig = await pumpFirstRun(tester);
    await _tap(tester, 'Continue');
    await _tap(tester, 'Continue');
    expect(rig.sent('PATCH', '/me'), isEmpty);
  });

  testWidgets(
    'the notifications step saves the chosen level and can ask the OS',
    (tester) async {
      final rig = await pumpFirstRun(tester);
      await _tap(tester, 'Continue');
      await _tap(tester, 'Continue');
      await _tap(tester, 'Mentions and direct messages');
      await _tap(tester, 'Allow notifications');
      expect(rig.push.registers, 1);
      await _tap(tester, 'Continue');

      final put = rig.sent('PUT', '/push/preference');
      expect(put, hasLength(1));
      expect(jsonDecode(put.first.body), {'preference': 'mentions'});
      expect(find.text('Check your voice'), findsOneWidget);
    },
  );

  testWidgets('keeping the current level sends no preference write', (
    tester,
  ) async {
    final rig = await pumpFirstRun(tester);
    await _tap(tester, 'Continue');
    await _tap(tester, 'Continue');
    await _tap(tester, 'Continue');
    expect(rig.sent('PUT', '/push/preference'), isEmpty);
  });

  testWidgets('back returns to the earlier step', (tester) async {
    await pumpFirstRun(tester);
    await _tap(tester, 'Continue');
    await _tap(tester, 'Back');
    expect(find.text('Welcome'), findsOneWidget);
  });

  testWidgets('finishing lands on the busiest text channel with no hint', (
    tester,
  ) async {
    await pumpFirstRun(tester);
    for (var i = 0; i < 3; i++) {
      await _tap(tester, 'Continue');
    }
    expect(find.text('Check your voice'), findsOneWidget);
    await _tap(tester, 'Finish');

    expect(find.text('channel:busy'), findsOneWidget);
    expect(
      find.textContaining('Voice channels are in the channel list'),
      findsNothing,
    );
    expect(find.text('Got it'), findsNothing);
  });

  testWidgets('a wide window shows a centred card, not a full page', (
    tester,
  ) async {
    await pumpFirstRun(tester);
    final card = tester.getRect(
      find
          .ancestor(of: find.text('Welcome'), matching: find.byType(Material))
          .first,
    );
    expect(card.width, kFirstRunCardWidth);
    expect(card.center.dx, 640);
    final skip = tester.getRect(find.text('Skip setup'));
    expect(skip.right, lessThan(900));
  });

  testWidgets('a phone width fills the screen', (tester) async {
    await pumpFirstRun(tester, size: const Size(390, 800));
    expect(tester.getRect(find.text('Skip setup')).right, greaterThan(340));
  });
}
