// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permission group headers share one letter spacing, the label token's,
/// whatever the title's length.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/admin/role_permissions_rows.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('GroupHeader tracks like the label token, whatever the length', (
    tester,
  ) async {
    for (final title in ['Space', 'Moderation', 'Channels & invites']) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: [AppTokens.dark]),
          home: Scaffold(body: GroupHeader(title: title)),
        ),
      );
      final text = tester.widget<Text>(find.text(title.toUpperCase()));
      expect(
        text.style!.letterSpacing,
        AppText.label.letterSpacing,
        reason: title,
      );
    }
  });
}
