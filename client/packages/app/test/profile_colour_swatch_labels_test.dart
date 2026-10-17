// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Each profile colour swatch is named by its colour, so a screen reader can
/// tell the six apart instead of hearing "Profile colour" six times.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/profile_fields_section.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('every swatch has its own accessible name', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meProvider.overrideWith((ref) => Completer<api.Me>().future),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: SingleChildScrollView(child: ProfileFieldsSection()),
          ),
        ),
      ),
    );
    await tester.pump();

    const names = ['Pink', 'Purple', 'Blue', 'Orange', 'Green', 'Magenta'];
    expect(names, hasLength(AppCanvasColors.cursors.length));
    for (final name in names) {
      expect(
        find.bySemanticsLabel(RegExp('^Profile colour: $name\$')),
        findsOneWidget,
        reason: '$name swatch',
      );
    }
    semantics.dispose();
  });
}
