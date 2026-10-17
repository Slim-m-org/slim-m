// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `CanvasOpenButton` shows for a voice channel or a DM, and hides for a text
/// channel. Voice-only was the original owner decision (backlog,
/// 2026-08-13); the owner has since asked for a DM canvas too, for a 1-on-1
/// working session, which is what `isDm` covers - `store/dms.rs`'s `DM_BASE`
/// now grants `USE_CANVAS`, so the route no longer 403s there.
///
/// The kind arrives as plain flags from the header that builds this rather
/// than from a store lookup, so these are pure widget tests with no database
/// and no async resolve - see the widget's own doc comment for why.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_open_button.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  required bool isVoice,
  bool isDm = false,
}) => tester.pumpWidget(
  UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: CanvasOpenButton(channelId: 'c1', isVoice: isVoice, isDm: isDm),
      ),
    ),
  ),
);

void main() {
  testWidgets('shows for a voice channel and hides for a text channel', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pump(tester, container, isVoice: false);
    await tester.pump();
    expect(find.bySemanticsLabel('Open canvas'), findsNothing);

    await _pump(tester, container, isVoice: true);
    await tester.pump();
    expect(find.bySemanticsLabel('Open canvas'), findsOneWidget);
  });

  testWidgets('shows for a DM too', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pump(tester, container, isVoice: false, isDm: true);
    await tester.pump();
    expect(find.bySemanticsLabel('Open canvas'), findsOneWidget);
  });

  testWidgets('tapping it opens this channel and tapping again closes it', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pump(tester, container, isVoice: true);
    await tester.pump();

    expect(container.read(canvasOpenProvider), isNull);
    await tester.tap(find.bySemanticsLabel('Open canvas'));
    await tester.pump();
    expect(container.read(canvasOpenProvider), 'c1');

    await tester.tap(find.bySemanticsLabel('Close canvas'));
    await tester.pump();
    expect(container.read(canvasOpenProvider), isNull);
  });
}
