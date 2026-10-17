// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mention pill must not read as extra spaces around the name.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('the pill adds less than a space of width around the name', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: MessageBody(
            content: 'Welcome, @alice! Make yourself at home.',
            knownUsernames: {'alice'},
          ),
        ),
      ),
    );

    final text = tester.getSize(find.text('@alice'));
    final pill = tester.getSize(
      find
          .ancestor(of: find.text('@alice'), matching: find.byType(Container))
          .first,
    );
    expect(pill.width - text.width, lessThanOrEqualTo(4));
  });
}
