// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The quote line is 16pt of caption text, so at touch density a finger needs
/// the padded hit area to land on it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/reply_quote.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';
import 'touch_hit_support.dart';

void main() {
  testWidgets('the quote line reaches the touch minimum at touch density', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        AppTouchTargets(
          enabled: true,
          child: Align(
            alignment: Alignment.topLeft,
            child: ReplyQuote(
              resolved: message(id: 'parent', content: 'the original text'),
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    expectTouchTarget(
      tester,
      find.byType(ReplyQuote),
      alignment: Alignment.topLeft,
    );
  });
}
