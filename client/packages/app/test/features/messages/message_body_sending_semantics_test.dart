// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A still-sending message dimmed its body but told a screen reader nothing:
/// the same text read identically whether the message was still in flight or
/// already delivered. See `message_text.dart`'s `MessageBody.announceSending`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, {required bool sending}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: MessageBody(
          content: 'hello there',
          knownUsernames: const {},
          dim: sending,
          announceSending: sending,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a still-sending message carries a Sending semantics label', (
    tester,
  ) async {
    await _pump(tester, sending: true);
    expect(find.bySemanticsLabel(RegExp('Sending')), findsOneWidget);
  });

  testWidgets('a delivered message carries no Sending semantics label', (
    tester,
  ) async {
    await _pump(tester, sending: false);
    expect(find.bySemanticsLabel(RegExp('Sending')), findsNothing);
  });
}
