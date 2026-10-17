// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The performance pane carries both memory dials - attachment preview quality
/// and the image-cache cap - each stating its current value with the default
/// marked, and none of the app-behaviour rows that moved to General.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/performance_settings_section.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('shows both dials, each with its default marked', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: SingleChildScrollView(child: PerformanceSettingsSection()),
          ),
        ),
      ),
    );

    expect(find.text('Auto-download media'), findsOneWidget);
    expect(find.text('Autoplay GIFs'), findsOneWidget);
    expect(find.text('Attachment preview quality'), findsOneWidget);
    expect(find.text('Image cache'), findsOneWidget);
    // Each row states its current value, every one the default; two read Always.
    expect(find.text('Always (default)'), findsNWidgets(2));
    expect(find.text('Sharp (default)'), findsOneWidget);
    expect(find.text('100 MB (default)'), findsOneWidget);
    // App behaviour lives on the General pane, not here.
    expect(find.text('Message page size'), findsNothing);
    expect(find.text('Startup splash'), findsNothing);
    expect(find.text('Start on login'), findsNothing);
  });
}
