// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Carrying a row in the desktop rail draws each piece of row chrome once.
///
/// Owner, live backlog 203: "overlapping UI isues when dragging a channel".
/// The floating copy sat over the original, which stayed as a dimmed row with
/// its own selection bar, kebab and hover tint, so at pick-up everything drew
/// twice. Real rows, real rail, real held mouse press at 1280.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/channel_rail.dart';
import 'package:slimm_app/src/widgets/channel_rail_selection_marker.dart';
import 'package:slimm_app/src/widgets/context_menu_region.dart';
import 'package:slimm_app/src/widgets/channel_rail_section_label.dart'
    show AddChannelGlyph;
import 'package:slimm_app/src/widgets/rail_drag_lift.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _pump(
  WidgetTester tester,
  String selected,
) async {
  tester.view.physicalSize = const Size(1280, 880);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer();
  final router = GoRouter(
    initialLocation: Routes.channel(selected),
    routes: [
      GoRoute(
        path: Routes.channelPattern,
        builder: (context, state) => const Scaffold(body: ChannelRail()),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

Finder get _lifted => find.byType(RailDragLift);
Finder get _kebab => find.byIcon(AppIcons.moreVertical);
Finder get _rowMarker => find.byKey(AppListRow.selectionMarkerKey);
Finder get _railBar => find.descendant(
  of: find.byType(SelectionMarkerLayer),
  matching: find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).borderRadius ==
            const BorderRadius.horizontal(
              right: Radius.circular(AppRadii.full),
            ),
  ),
);

Future<TestGesture> _carry(WidgetTester tester, String name) async {
  final at = tester.getCenter(find.text(name).first);
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: at);
  await tester.pump();
  await gesture.down(at);
  await tester.pump(const Duration(milliseconds: 400));
  await gesture.moveTo(at + const Offset(0, 6));
  await tester.pump(const Duration(milliseconds: 400));
  expect(_lifted, findsOneWidget, reason: 'the hold must have lifted $name');
  return gesture;
}

Future<void> _finish(
  WidgetTester tester,
  TestGesture gesture,
  ({ProviderContainer container, SlimmDatabase db}) fixture,
) async {
  await gesture.up();
  await tester.pumpAndSettle();
  await teardownFixture(tester, fixture.container, fixture.db);
}

void main() {
  testWidgets('a carried selected channel draws its bar once, on the copy', (
    tester,
  ) async {
    final fixture = await _pump(tester, 'c-general');
    final gesture = await _carry(tester, 'general');

    final bars = _rowMarker.evaluate().length + _railBar.evaluate().length;
    expect(bars, 1, reason: 'one selection bar on screen while carrying');
    expect(
      find.descendant(of: _lifted, matching: _rowMarker),
      findsOneWidget,
      reason: 'and it belongs to the carried copy',
    );
    await _finish(tester, gesture, fixture);
  });

  testWidgets('the carried copy has no kebab and the slot keeps none', (
    tester,
  ) async {
    final fixture = await _pump(tester, 'c-general');
    final resting = _kebab.evaluate().length;
    final gesture = await _carry(tester, 'general');

    expect(find.descendant(of: _lifted, matching: _kebab), findsNothing);
    expect(
      _kebab.evaluate().length,
      resting - 1,
      reason: 'the lifted row contributes no kebab, copy or slot',
    );
    await _finish(tester, gesture, fixture);
  });

  testWidgets('the label is drawn by the copy alone and the bar stays put', (
    tester,
  ) async {
    final fixture = await _pump(tester, 'c-design');
    final gesture = await _carry(tester, 'general');

    expect(find.text('general'), findsOneWidget);
    expect(_rowMarker, findsNothing, reason: 'general is not selected');
    expect(_railBar.evaluate().length, 1, reason: 'design keeps its bar');
    await _finish(tester, gesture, fixture);
  });

  testWidgets('the copy sits exactly on the row face, not its padding', (
    tester,
  ) async {
    final fixture = await _pump(tester, 'c-design');
    final row = tester.getRect(find.widgetWithText(AppListRow, 'general'));
    final gesture = await _carry(tester, 'general');

    final copy = tester.getRect(_lifted);
    expect(copy.left, closeTo(row.left, 3), reason: 'copy aligns to the row');
    expect(copy.width, closeTo(row.width, 6), reason: 'and is as wide');
    await _finish(tester, gesture, fixture);
  });

  testWidgets('no other row shows hover chrome while carrying', (tester) async {
    final fixture = await _pump(tester, 'c-design');
    final gesture = await _carry(tester, 'general');
    await gesture.moveTo(tester.getCenter(find.text('design').first));
    await tester.pump(const Duration(milliseconds: 400));

    final shown = tester
        .widgetList<AnimatedOpacity>(
          find.ancestor(of: _kebab, matching: find.byType(AnimatedOpacity)),
        )
        .where((o) => o.opacity > 0);
    expect(shown, isEmpty, reason: 'no kebab revealed by a hover mid-carry');
    await _finish(tester, gesture, fixture);
  });

  testWidgets('a carried category is its label alone, with no menu or glyph', (
    tester,
  ) async {
    final fixture = await _pump(tester, 'c-general');
    final gesture = await _carry(tester, 'Voice');

    expect(
      find.descendant(of: _lifted, matching: find.byType(ContextMenuRegion)),
      findsNothing,
    );
    final glyphs = tester.widgetList<AddChannelGlyph>(
      find.descendant(of: _lifted, matching: find.byType(AddChannelGlyph)),
    );
    expect(glyphs.where((g) => g.revealed), isEmpty);
    await _finish(tester, gesture, fixture);
  });
}
