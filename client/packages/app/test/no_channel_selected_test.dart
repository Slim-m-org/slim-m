// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// shell.md: this is the very first screen a fresh desktop sign-in lands
/// on, and it used to be a single small line of grey text with no icon and
/// no next step - noticeably less than the functionally identical
/// `ChannelStartHeader` gets. Confirms it now carries the same visual
/// weight and names the actual next step.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/first_run/providers/first_run_controller.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_design_system/design_system.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required bool touch,
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: AppTouchTargets(
          enabled: touch,
          child: const Scaffold(body: NoChannelSelected()),
        ),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('carries an icon and a heading, not just a bare line', (
    tester,
  ) async {
    await _pump(tester, touch: false);

    expect(find.byIcon(AppIcons.hash), findsOneWidget);
    expect(find.text('Pick a channel to start reading.'), findsOneWidget);
  });

  testWidgets('names the actual next step, keyboard-aware', (tester) async {
    // Keycaps now, not a sentence; same rule about who sees them.
    await _pump(tester, touch: false);
    expect(find.byType(AppKbd), findsWidgets);
    expect(find.text('Quick switcher'), findsOneWidget);

    await _pump(tester, touch: true);
    expect(find.byType(AppKbd), findsNothing);
  });

  testWidgets('guides a member who skipped setup, on both layouts', (
    tester,
  ) async {
    for (final touch in [false, true]) {
      await _pump(tester, touch: touch);
      expect(
        find.textContaining('Pick a channel from the list'),
        findsOneWidget,
      );
      expect(find.textContaining('Open a voice channel'), findsOneWidget);
      expect(find.text('Run setup'), findsOneWidget);
    }
  });

  testWidgets('Run setup opens the flow again', (tester) async {
    final container = await _pump(tester, touch: true);
    await tester.tap(find.text('Run setup'));
    await tester.pump();
    final state = container.read(firstRunControllerProvider);
    expect((state.active, state.replay), (true, true));
  });

  testWidgets('the shortcut list is centred under the heading', (tester) async {
    // The seam once sat right of centre because keycaps set the row's end.
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, touch: false);

    final centre = tester.getCenter(find.byIcon(AppIcons.hash)).dx;
    expect(centre, moreOrLessEquals(240, epsilon: 0.5));
    expect(
      tester.getCenter(find.text('Pick a channel to start reading.')).dx,
      moreOrLessEquals(centre, epsilon: 0.5),
    );
    for (final label in [
      'Quick switcher',
      'Next channel',
      'Previous channel',
      'Open settings',
    ]) {
      final row = find.ancestor(
        of: find.text(label),
        matching: find.byType(Row),
      );
      final kbd = find.descendant(of: row.first, matching: find.byType(AppKbd));
      final labelRight = tester.getTopRight(find.text(label)).dx;
      final keysLeft = tester.getTopLeft(kbd.first).dx;
      expect(labelRight, lessThanOrEqualTo(centre), reason: label);
      expect(keysLeft, greaterThanOrEqualTo(centre), reason: label);
      expect(
        (labelRight + keysLeft) / 2,
        moreOrLessEquals(centre, epsilon: 1),
        reason: label,
      );
    }
  });
}
