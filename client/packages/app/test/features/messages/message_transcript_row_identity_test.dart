// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message arriving shifts every built row's index by one; each row must
/// still be the same element afterwards, or its local state (an open edit
/// field, a revealed spoiler, a playing video) is thrown away on every arrival.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/transcript_slots.dart';
import 'package:slimm_data/data.dart';

import '../../message_transcript_extent_harness.dart';

Element _row(WidgetTester tester, String id) =>
    tester.element(find.byKey(ValueKey(id)));

Future<void> _mount(
  WidgetTester tester,
  ScrollController controller,
  List<Message> rows,
) async {
  await tester.pumpWidget(
    app(transcript(controller: controller, count: rows.length, rows: rows)),
  );
  await tester.pump();
}

void main() {
  testWidgets('every built row keeps its element when a message arrives', (
    tester,
  ) async {
    sizeViewport(tester);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final all = shortMessages(40);
    await _mount(tester, controller, all.sublist(0, 39));

    final visible = [
      for (final m in all.sublist(0, 39))
        if (find.byKey(ValueKey(m.id)).evaluate().isNotEmpty) m.id,
    ];
    expect(visible.length, greaterThan(5));
    final before = {for (final id in visible) id: _row(tester, id)};

    await _mount(tester, controller, all);

    final kept = [
      for (final id in visible)
        if (find.byKey(ValueKey(id)).evaluate().isNotEmpty) id,
    ];
    expect(kept.length, greaterThan(5));
    for (final id in kept) {
      expect(
        identical(_row(tester, id), before[id]),
        isTrue,
        reason: '$id was remounted by an unrelated arrival',
      );
    }
    expect(find.byKey(const ValueKey('s39')), findsOneWidget);
  });

  testWidgets(
    'the row an arrival displaces from the newest slot stays mounted',
    (tester) async {
      sizeViewport(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final all = shortMessages(10);
      await _mount(tester, controller, all.sublist(0, 9));
      final newest = _row(tester, 's8');

      await _mount(tester, controller, all);

      expect(identical(_row(tester, 's8'), newest), isTrue);
    },
  );

  testWidgets('only the arriving row plays the entrance', (tester) async {
    sizeViewport(tester);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final all = shortMessages(10);
    await _mount(tester, controller, all.sublist(0, 9));
    await tester.pumpAndSettle();

    await _mount(tester, controller, all);
    await tester.pump(const Duration(milliseconds: 20));

    double opacityOf(String id) {
      final row = find.descendant(
        of: find.byKey(ValueKey(id)),
        matching: find.byType(MessageRow),
      );
      final fades = find.ancestor(of: row, matching: find.byType(Opacity));
      return fades.evaluate().isEmpty
          ? 1
          : tester.widget<Opacity>(fades.first).opacity;
    }

    expect(opacityOf('s9'), lessThan(1));
    expect(opacityOf('s8'), 1);
  });

  testWidgets('a deletion above a row does not remount it either', (
    tester,
  ) async {
    sizeViewport(tester);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final all = shortMessages(10);
    await _mount(tester, controller, all);
    final kept = _row(tester, 's2');
    final newest = _row(tester, 's9');

    await _mount(tester, controller, [...all]..removeAt(5));

    expect(find.byKey(const ValueKey('s5')), findsNothing);
    expect(identical(_row(tester, 's2'), kept), isTrue);
    expect(identical(_row(tester, 's9'), newest), isTrue);
  });

  testWidgets('the start of the channel survives an arrival', (tester) async {
    sizeViewport(tester);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final all = shortMessages(6);
    await _mount(tester, controller, all.sublist(0, 5));
    final start = tester.element(find.byType(TranscriptTopSlot));

    await _mount(tester, controller, all);

    expect(
      identical(tester.element(find.byType(TranscriptTopSlot)), start),
      isTrue,
    );
  });
}
