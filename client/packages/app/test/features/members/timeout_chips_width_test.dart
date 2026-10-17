// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The timeout chooser has to fit the member pane, which is the narrowest
/// place it is shown.
///
/// Two separate defects made it unreadable there, both visible in the same
/// screenshot: two of the four duration buttons rendered as empty boxes.
///
/// The buttons were four `Expanded` in a `Row`. Expanded makes each child's
/// width the row's decision rather than the label's, and at 236px that left
/// each button narrower than its own padding plus text, so every label was
/// clipped to a fixed 16px and the shorter ones vanished into it.
///
/// Separately, the "Time out for..." header put its `Text` in a `Row` with no
/// `Flexible` around it, so the row wanted 46px more than the pane had. That
/// one predates the chips being used here at all and only shows at this width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile_sections.dart';
import 'package:slimm_design_system/design_system.dart';

/// The member pane's own width, less the selection bar's horizontal padding:
/// what `MemberSelectionBar` actually hands the chooser. See its doc for the
/// 236 - `member_pane_rows.dart` is where that number comes from.
const _paneContentWidth = 212.0;

Future<void> _pumpAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: TimeoutDurationChips(onChosen: (_) {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final width in const [_paneContentWidth, 320.0, 520.0]) {
    testWidgets('nothing overflows at ${width}px', (tester) async {
      await _pumpAt(tester, width);
      expect(
        tester.takeException(),
        isNull,
        reason:
            'the chooser must lay out inside $width px; the member pane is '
            'the narrowest surface that shows it',
      );
    });

    testWidgets('every duration is legible at ${width}px', (tester) async {
      await _pumpAt(tester, width);
      // Each label at its natural width; clipping is what made them all equal.
      final widths = <String, double>{
        for (final label in ['5m', '1h', '24h', '7d'])
          label: tester.getSize(find.text(label)).width,
      };
      expect(
        widths['24h'],
        greaterThan(widths['5m']!),
        reason: 'a three-character label must be wider than a two: $widths',
      );
      for (final entry in widths.entries) {
        expect(
          entry.value,
          greaterThan(20),
          reason: 'clipped to nothing at ${width}px: $widths',
        );
      }
    });
  }

  testWidgets('each duration keeps its own accessible name', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpAt(tester, _paneContentWidth);
    for (final label in ['5m', '1h', '24h', '7d']) {
      expect(
        find.bySemanticsLabel('Time out for $label'),
        findsOneWidget,
        reason: '"$label" alone does not say what the button does',
      );
    }
    handle.dispose();
  });
}
