// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Click-and-hold reordering of the channel rail at pointer width: a held
/// press lifts a channel or a category, an insertion line shows where it will
/// land, release places it and Escape cancels (`desktop-vs-mobile.md` rules 1
/// and 3). Real mouse gestures, and the line is asserted by its geometry.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show ChannelOrderGroup;
import 'package:slimm_app/src/widgets/channel_rail_reorder.dart';
import 'package:slimm_app/src/widgets/rail_carry_slot.dart';
import 'package:slimm_app/src/widgets/rail_drag_lift.dart';
import 'package:slimm_app/src/widgets/rail_drop_slots.dart';
import 'package:slimm_app/src/widgets/rail_insertion_line.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

Channel _channel(String id) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

ChannelCategoryRow _cat(String id) =>
    ChannelCategoryRow(id: id, name: id, position: 0);

const _rowH = 40.0;
const _headerH = 28.0;
const _hold = Duration(milliseconds: 400);

final _c1 = _cat('c1');
final _c2 = _cat('c2');
final _c3 = _cat('c3');

List<ChannelSection> _sections() => [
  (null, [_channel('a')]),
  (_c1, [_channel('b'), _channel('c')]),
  (_c2, [_channel('d')]),
  (_c3, <Channel>[]),
];

class _Rail {
  final channelReports = <List<ChannelOrderGroup>>[];
  final categoryReports = <List<String>>[];
  final taps = <String>[];
  final ScrollController scroll = ScrollController();
}

Future<_Rail> _pump(
  WidgetTester tester, {
  List<ChannelSection>? sections,
  double height = 900,
  bool hideEmptyUncategorised = false,
}) async {
  tester.view.physicalSize = Size(1280, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final rail = _Rail();
  addTearDown(rail.scroll.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          controller: rail.scroll,
          child: ReorderableChannelRows(
            sections: sections ?? _sections(),
            canManage: true,
            onReorder: rail.channelReports.add,
            onReorderCategories: rail.categoryReports.add,
            rowBuilder: (c, _) => GestureDetector(
              onTap: () => rail.taps.add(c.id),
              child: SizedBox(height: _rowH, child: Text(c.id)),
            ),
            carriedRowBuilder: (c) =>
                SizedBox(height: _rowH, child: Text('${c.id}-carried')),
            headerBuilder: (c) => c == null && hideEmptyUncategorised
                ? const SizedBox.shrink()
                : SizedBox(
                    height: _headerH,
                    child: Text('header:${c?.id ?? 'none'}'),
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return rail;
}

Future<TestGesture> _press(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await tester.pump(_hold);
  return gesture;
}

Future<void> _carryTo(
  WidgetTester tester,
  TestGesture gesture,
  Offset from,
  Offset to,
) async {
  for (var i = 1; i <= 12; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / 12)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
}

double _lineY(WidgetTester tester) =>
    tester.getRect(find.byType(RailInsertionLine)).center.dy;

Rect _rect(WidgetTester tester, String text) =>
    tester.getRect(find.text(text).first);

List<String>? _ids(List<ChannelOrderGroup> groups, String? categoryId) => groups
    .where((g) => g.categoryId == categoryId)
    .map((g) => g.channelIds)
    .firstOrNull;

void main() {
  testWidgets('a quick press and a short drag never lift', (tester) async {
    final rail = await _pump(tester);
    final at = tester.getCenter(find.text('b'));

    final quick = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 80));
    await quick.up();
    await tester.pumpAndSettle();
    expect(find.byType(RailDragLift), findsNothing);
    expect(rail.taps, ['b'], reason: 'a plain click still reaches the row');

    final drag = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 100));
    await drag.moveBy(const Offset(0, 60));
    await tester.pump(_hold);
    expect(find.byType(RailDragLift), findsNothing);
    await drag.up();
    await tester.pumpAndSettle();
    expect(rail.channelReports, isEmpty);
  });

  testWidgets('a hold lifts a floating copy over a quiet slot', (tester) async {
    await _pump(tester);
    final gesture = await _press(tester, tester.getCenter(find.text('b')));

    expect(find.byType(RailDragLift), findsOneWidget);
    expect(find.text('b-carried'), findsOneWidget);
    expect(find.text('b'), findsNothing, reason: 'the row is not drawn twice');
    expect(find.byType(RailCarrySlot), findsOneWidget);
    await gesture.up();
  });

  testWidgets('the line sits on the gap between the two neighbouring rows', (
    tester,
  ) async {
    final rail = await _pump(tester);
    final from = tester.getCenter(find.text('a'));
    final gesture = await _press(tester, from);
    final b = _rect(tester, 'b');
    final c = _rect(tester, 'c');
    await _carryTo(tester, gesture, from, Offset(from.dx, b.bottom + 1));

    expect(find.byType(RailInsertionLine), findsOneWidget);
    expect(_lineY(tester), closeTo((b.bottom + c.top) / 2, 0.5));
    await gesture.up();
    await tester.pumpAndSettle();

    final groups = rail.channelReports.single;
    expect(_ids(groups, 'c1'), ['b', 'a', 'c']);
    expect(_ids(groups, null), isEmpty);
    expect(_ids(groups, 'c2'), ['d']);
    expect(_ids(groups, 'c3'), isEmpty);
  });

  testWidgets('the line sits under the last row at the end of a category', (
    tester,
  ) async {
    final rail = await _pump(tester);
    final from = tester.getCenter(find.text('a'));
    final gesture = await _press(tester, from);
    final c = _rect(tester, 'c');
    await _carryTo(tester, gesture, from, Offset(from.dx, c.bottom - 4));

    expect(_lineY(tester), closeTo(c.bottom, 0.5));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_ids(rail.channelReports.single, 'c1'), ['b', 'c', 'a']);
  });

  testWidgets('the line sits under the header of an empty category', (
    tester,
  ) async {
    final rail = await _pump(tester);
    final from = tester.getCenter(find.text('b'));
    final gesture = await _press(tester, from);
    final header = _rect(tester, 'header:c3');
    await _carryTo(tester, gesture, from, Offset(from.dx, header.bottom - 4));

    expect(_lineY(tester), closeTo(header.bottom, 0.5));
    await gesture.up();
    await tester.pumpAndSettle();
    final groups = rail.channelReports.single;
    expect(_ids(groups, 'c3'), ['b']);
    expect(_ids(groups, 'c1'), ['c']);
  });

  testWidgets('an undrawn uncategorised section is reached above the first '
      'header without moving the rail', (tester) async {
    final rail = await _pump(
      tester,
      sections: [
        (null, <Channel>[]),
        (_c1, [_channel('b'), _channel('c')]),
      ],
      hideEmptyUncategorised: true,
    );
    final first = _rect(tester, 'header:c1');
    final from = tester.getCenter(find.text('c'));
    final gesture = await _press(tester, from);
    expect(_rect(tester, 'header:c1'), first, reason: 'nothing shifts');
    await _carryTo(tester, gesture, from, Offset(from.dx, first.top + 2));

    expect(_lineY(tester), closeTo(first.top, 0.5));
    await gesture.up();
    await tester.pumpAndSettle();
    final groups = rail.channelReports.single;
    expect(_ids(groups, null), ['c']);
    expect(_ids(groups, 'c1'), ['b']);
  });

  testWidgets('rows do not shuffle while a channel is carried', (tester) async {
    await _pump(tester);
    final before = _rect(tester, 'c');
    final from = tester.getCenter(find.text('a'));
    final gesture = await _press(tester, from);
    await _carryTo(tester, gesture, from, Offset(from.dx, before.top + 4));
    expect(_rect(tester, 'c'), before);
    await gesture.up();
  });

  testWidgets('a lifted category collapses and the line sits between blocks', (
    tester,
  ) async {
    final rail = await _pump(tester);
    final from = tester.getCenter(find.text('header:c1'));
    final gesture = await _press(tester, from);

    expect(find.byType(RailDragLift), findsOneWidget);
    expect(find.text('b'), findsNothing, reason: 'its channels fold away');
    expect(find.text('c'), findsNothing);
    final c3 = _rect(tester, 'header:c3');
    final d = _rect(tester, 'd');
    await _carryTo(tester, gesture, from, Offset(from.dx, d.center.dy + 12));

    expect(_lineY(tester), closeTo(c3.top, 0.5));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(rail.categoryReports.single, ['c2', 'c1', 'c3']);
    expect(rail.channelReports, isEmpty);
  });

  testWidgets('a category can land at the very start and the very end', (
    tester,
  ) async {
    final rail = await _pump(tester);
    final from = tester.getCenter(find.text('header:c2'));
    var gesture = await _press(tester, from);
    final first = _rect(tester, 'header:c1');
    await _carryTo(tester, gesture, from, Offset(from.dx, first.top + 2));
    expect(_lineY(tester), closeTo(first.top, 0.5));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(rail.categoryReports.last, ['c2', 'c1', 'c3']);

    final c3 = tester.getCenter(find.text('header:c3'));
    final c2 = tester.getCenter(find.text('header:c2'));
    gesture = await _press(tester, c2);
    final last = _rect(tester, 'header:c3');
    await _carryTo(tester, gesture, c2, c3);
    await gesture.moveTo(Offset(c3.dx, last.bottom + 20));
    await tester.pump();
    expect(_lineY(tester), closeTo(last.bottom, 0.5));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(rail.categoryReports.last, ['c1', 'c3', 'c2']);
  });

  testWidgets('Escape cancels the carry and reports nothing', (tester) async {
    final rail = await _pump(tester);
    final from = tester.getCenter(find.text('a'));
    final gesture = await _press(tester, from);
    await _carryTo(
      tester,
      gesture,
      from,
      Offset(from.dx, _rect(tester, 'd').top),
    );
    expect(find.byType(RailInsertionLine), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(RailInsertionLine), findsNothing);
    expect(find.byType(RailDragLift), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(rail.channelReports, isEmpty);
    expect(rail.taps, isEmpty);
  });

  testWidgets('dropping on its own position reports nothing and selects '
      'nothing', (tester) async {
    final rail = await _pump(tester);
    final from = tester.getCenter(find.text('c'));
    final gesture = await _press(tester, from);
    await _carryTo(tester, gesture, from, from + const Offset(0, 6));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(rail.channelReports, isEmpty);
    expect(rail.categoryReports, isEmpty);
    expect(rail.taps, isEmpty);
    expect(find.byType(RailInsertionLine), findsNothing);
  });

  testWidgets('carrying near the bottom edge scrolls the rail', (tester) async {
    final many = [
      (null, [for (var i = 0; i < 30; i++) _channel('r$i')]),
    ];
    final rail = await _pump(tester, sections: many, height: 400);
    final from = tester.getCenter(find.text('r1'));
    final gesture = await _press(tester, from);
    await _carryTo(tester, gesture, from, const Offset(100, 392));
    await tester.pump(const Duration(seconds: 3));

    expect(rail.scroll.offset, rail.scroll.position.maxScrollExtent);
    expect(find.byType(RailInsertionLine), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_ids(rail.channelReports.single, null)!.last, 'r1');
  });

  testWidgets('every channel and category header offers move actions', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    for (final label in ['c', 'header:c2']) {
      final data = tester.getSemantics(find.text(label)).getSemanticsData();
      expect(data.customSemanticsActionIds, isNotEmpty, reason: label);
    }
    handle.dispose();
  });

  group('drop arithmetic', () {
    test('a forward move within a section lands after the row it passed', () {
      final groups = groupsAfterDrop(_sections(), 'b', const DropSlot(1, 2, 0));
      expect(_ids(groups!, 'c1'), ['c', 'b']);
    });

    test('either gap beside the carried row is no move at all', () {
      expect(groupsAfterDrop(_sections(), 'b', const DropSlot(1, 0, 0)), null);
      expect(groupsAfterDrop(_sections(), 'b', const DropSlot(1, 1, 0)), null);
    });

    test('a category dropped beside itself is no move', () {
      expect(categoryIdsAfterDrop(['x', 'y', 'z'], 'y', 1), null);
      expect(categoryIdsAfterDrop(['x', 'y', 'z'], 'y', 2), null);
      expect(categoryIdsAfterDrop(['x', 'y', 'z'], 'y', 3), ['x', 'z', 'y']);
      expect(categoryIdsAfterDrop(['x', 'y', 'z'], 'z', 0), ['z', 'x', 'y']);
    });
  });
}
