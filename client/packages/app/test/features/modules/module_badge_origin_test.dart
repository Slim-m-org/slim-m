// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module-drawn badge never wears a built-in chip's variant and always names
/// the module it came from, on hover, long-press and to a screen reader.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_slot_view.dart';
import 'package:slimm_design_system/design_system.dart';

const _moduleVariants = {
  AppBadgeVariant.module,
  AppBadgeVariant.moduleAccent,
  AppBadgeVariant.moduleMuted,
};

Future<void> _pump(WidgetTester tester, api.ModuleSlotNode node) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ModuleSlotView(
              api.ModuleSlotItem(nodes: [node]),
              source: 'xp-module',
              inline: true,
            ),
          ),
        ),
      ),
    );

void main() {
  for (final tone in api.ModuleSlotTone.values) {
    testWidgets('a module badge never uses a built-in variant, $tone', (
      tester,
    ) async {
      await _pump(tester, api.ModuleSlotBadge('Admin', tone: tone));

      final badge = tester.widget<AppBadge>(find.byType(AppBadge));
      expect(_moduleVariants, contains(badge.variant));
      expect(find.text('ADMIN'), findsNothing);
      expect(find.text('Admin'), findsOneWidget);
    });
  }

  testWidgets('accent changes only colour, and never fills', (tester) async {
    await _pump(
      tester,
      const api.ModuleSlotBadge('Admin', tone: api.ModuleSlotTone.accent),
    );

    const tokens = AppTokens.light;
    final box =
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byType(AppBadge),
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(box.color, isNull);
    expect((box.border! as Border).top.color, tokens.accent);
    expect(tester.widget<Text>(find.text('Admin')).style!.color, tokens.accent);
  });

  testWidgets('the origin marker leads and the tooltip names the source', (
    tester,
  ) async {
    await _pump(tester, const api.ModuleSlotBadge('Admin'));

    final badge = tester.widget<AppBadge>(find.byType(AppBadge));
    expect(badge.markerIcon, AppIcons.dock);
    expect(
      tester.getTopLeft(find.byIcon(AppIcons.dock)).dx,
      lessThan(tester.getTopLeft(find.text('Admin')).dx),
    );
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'From xp-module',
    );
  });

  testWidgets('a long press shows the source on touch', (tester) async {
    await _pump(tester, const api.ModuleSlotBadge('Admin'));

    await tester.longPress(find.byType(AppBadge));
    await tester.pump();

    expect(find.text('From xp-module'), findsOneWidget);
  });

  testWidgets('hovering with a pointer shows the source', (tester) async {
    await _pump(tester, const api.ModuleSlotBadge('Admin'));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(AppBadge)));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('From xp-module'), findsOneWidget);
  });

  testWidgets('the semantics label carries the source', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, const api.ModuleSlotBadge('Admin'));

    expect(find.bySemanticsLabel('Admin, from xp-module'), findsOneWidget);
    handle.dispose();
  });
}
