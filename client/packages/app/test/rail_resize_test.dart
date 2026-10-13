// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Dragging the channel rail's edge sets its width anywhere between the two
/// limits, stores it, and a click still narrows and widens it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/rail_width_preference.dart';
import 'package:slimm_app/src/widgets/channel_rail.dart';
import 'package:slimm_app/src/widgets/rail_drag_handle.dart';
import 'package:slimm_design_system/design_system.dart';

Future<ProviderContainer> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: Row(
            children: [
              SizedBox(width: 248),
              RailDragHandle(railWidth: 248),
              Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    ),
  );
  return container;
}

/// Just inside the rail, where the handle's grab area reaches back to.
Offset _edge(WidgetTester tester) =>
    tester.getCenter(find.byType(RailDragHandle)) - const Offset(4, 0);

void main() {
  testWidgets('a drag sets the width it ends on and stores it', (tester) async {
    final container = await _pump(tester);
    final edge = _edge(tester);
    final gesture = await tester.startGesture(edge);
    await gesture.moveBy(const Offset(20, 0));
    expect(container.read(railDraggingProvider), isTrue);
    await gesture.moveBy(const Offset(40, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(container.read(railDraggingProvider), isFalse);
    expect(container.read(railWidthControllerProvider), 308);
    expect(container.read(channelRailExpandedProvider), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(railWidthKey), 308);
  });

  testWidgets('a drag past either limit stops at it', (tester) async {
    final container = await _pump(tester);
    final edge = _edge(tester);
    await tester.dragFrom(edge, const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(container.read(railWidthControllerProvider), railMaxWidth);

    await tester.dragFrom(edge, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(container.read(railWidthControllerProvider), railMinWidth);
  });

  testWidgets('a click still narrows and widens the rail', (tester) async {
    final container = await _pump(tester);
    await tester.tapAt(_edge(tester));
    await tester.pump();
    expect(container.read(channelRailExpandedProvider), isFalse);
    await tester.tapAt(_edge(tester));
    await tester.pump();
    expect(container.read(channelRailExpandedProvider), isTrue);
    expect(container.read(railWidthControllerProvider), isNull);
  });

  test('a stored width comes back clamped, and junk is ignored', () async {
    for (final (stored, expected) in [
      (300.0, 300.0),
      (9000.0, railMaxWidth),
      (12.0, railMinWidth),
    ]) {
      SharedPreferences.setMockInitialValues({railWidthKey: stored});
      final container = ProviderContainer();
      await container.read(railWidthControllerProvider.notifier).restore();
      expect(container.read(railWidthControllerProvider), expected);
      container.dispose();
    }
    SharedPreferences.setMockInitialValues({railWidthKey: 'wide'});
    final container = ProviderContainer();
    await container.read(railWidthControllerProvider.notifier).restore();
    expect(container.read(railWidthControllerProvider), isNull);
    container.dispose();
  });
}
