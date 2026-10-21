// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The offline marker of a bot command row stays readable at phone width,
/// however long the description before it is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_items.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('offline survives a long detail at 390 wide', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ComposerAutocomplete(
            suggestions: const [
              AutocompleteSuggestion(
                insert: '!play ',
                label: '!play',
                detail:
                    'Plays a very long description of a song from the queue · Jellyfin',
                offline: true,
              ),
            ],
            selected: 0,
            onPick: (_) {},
            onHover: (_) {},
          ),
        ),
      ),
    );
    final marker = find.text('offline');
    expect(marker, findsOneWidget);
    expect(tester.getRect(marker).right, lessThanOrEqualTo(390));
    expect(tester.getRect(marker).width, greaterThan(20));
  });
}
