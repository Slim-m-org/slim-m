// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Carrying categories and channels through a two-level rail at pointer width
/// (decision 0120): filing a category under another, and the refused line a
/// third level gets instead of a drop.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show CategoryOrderGroup, ChannelOrderGroup;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_reorder.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_insertion_line.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

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

const _gamers = ChannelCategoryRow(id: 'gamers', name: 'gamers', position: 0);
const _minecraft = ChannelCategoryRow(
  id: 'minecraft',
  name: 'minecraft',
  position: 0,
  parentId: 'gamers',
);
const _cs2 = ChannelCategoryRow(
  id: 'cs2',
  name: 'cs2',
  position: 1,
  parentId: 'gamers',
);
const _music = ChannelCategoryRow(id: 'music', name: 'music', position: 1);

List<ChannelSection> _sections() => [
  (null, <Channel>[]),
  (_gamers, [_channel('lobby')]),
  (_minecraft, [_channel('survival')]),
  (_cs2, [_channel('ranked'), _channel('casual')]),
  (_music, [_channel('jazz')]),
];

class _Rail {
  final channelReports = <List<ChannelOrderGroup>>[];
  final categoryReports = <List<CategoryOrderGroup>>[];
}

Future<_Rail> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final rail = _Rail();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReorderableChannelRows(
            sections: _sections(),
            canManage: true,
            categoriesNest: true,
            carriedRowInset: 16,
            onReorder: rail.channelReports.add,
            onReorderCategories: rail.categoryReports.add,
            rowBuilder: (c, _) => SizedBox(height: 40, child: Text(c.id)),
            headerBuilder: (c) => SizedBox(
              height: c == null ? 0 : 28,
              child: Text('header:${c?.id}'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return rail;
}

Future<TestGesture> _carry(WidgetTester tester, String from, double toY) async {
  final start = tester.getCenter(find.text(from));
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 400));
  for (var i = 1; i <= 12; i++) {
    await gesture.moveTo(
      Offset(start.dx, start.dy + (toY - start.dy) * i / 12),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  return gesture;
}

final _line = find.byWidgetPredicate((w) => w is RailInsertionLine);

bool get _refusedShown =>
    find.text(RailInsertionLine.refusedReason).evaluate().isNotEmpty;

List<String> _shape(List<CategoryOrderGroup> groups) => [
  for (final g in groups) '${g.parentId}:${g.categoryIds.join(',')}',
];

void main() {
  testWidgets('a category carried over the end of a block is filed inside it', (
    tester,
  ) async {
    final rail = await _pump(tester);
    final blockEnd = tester.getRect(find.text('casual')).bottom;
    final gesture = await _carry(tester, 'header:music', blockEnd - 4);

    expect(_refusedShown, isFalse);
    expect(tester.getRect(_line).left, greaterThan(16));
    await gesture.up();
    await pumpFrames(tester);

    expect(_shape(rail.categoryReports.single), [
      'null:gamers',
      'gamers:minecraft,cs2,music',
    ]);
  });

  testWidgets('a category carried between a sub-category\'s rows is refused, '
      'and the drop sends nothing', (tester) async {
    final rail = await _pump(tester);
    final between = tester.getRect(find.text('ranked')).bottom;
    final gesture = await _carry(tester, 'header:music', between);

    expect(_refusedShown, isTrue);
    await gesture.up();
    await pumpFrames(tester);

    expect(rail.categoryReports, isEmpty);
    expect(_refusedShown, isFalse, reason: 'the line goes with the carry');
  });

  testWidgets('a category with sub-categories cannot be filed under another', (
    tester,
  ) async {
    final rail = await _pump(tester);
    final gesture = await _carry(tester, 'header:gamers', 1000);
    final musicEnd = tester.getRect(find.text('jazz')).bottom;
    await gesture.moveTo(Offset(100, musicEnd - 4));
    await tester.pump();

    expect(_refusedShown, isTrue);
    await gesture.moveTo(Offset(100, musicEnd + 4));
    await tester.pump();
    expect(_refusedShown, isFalse);
    await gesture.up();
    await pumpFrames(tester);

    expect(_shape(rail.categoryReports.single), [
      'null:music,gamers',
      'gamers:minecraft,cs2',
    ]);
  });

  testWidgets('a channel lands in a sub-category, its line one step in', (
    tester,
  ) async {
    final rail = await _pump(tester);
    final topLevelGap = tester.getRect(find.text('lobby')).top;
    var gesture = await _carry(tester, 'jazz', topLevelGap);
    final topLevelLeft = tester.getRect(_line).left;
    await gesture.up();
    await pumpFrames(tester);

    gesture = await _carry(
      tester,
      'jazz',
      tester.getRect(find.text('ranked')).top,
    );
    expect(tester.getRect(_line).left - topLevelLeft, closeTo(16, 0.5));
    await gesture.up();
    await pumpFrames(tester);

    final into = rail.channelReports.last
        .firstWhere((g) => g.categoryId == 'cs2')
        .channelIds;
    expect(into, ['jazz', 'ranked', 'casual']);
  });
}
