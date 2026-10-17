// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Real-pointer drags of one channel row into every kind of category target
/// the rail offers: a header, another category's rows, the space under the
/// last row, an empty category, and out of the uncategorised group.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show ChannelOrderGroup;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_reorder.dart';
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

Future<List<ChannelOrderGroup>?> _drag(
  WidgetTester tester, {
  required List<ChannelSection> sections,
  required String channel,
  required Finder target,
  double targetDy = 0,
}) async {
  List<ChannelOrderGroup>? reported;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReorderableChannelRows(
            sections: sections,
            canManage: true,
            onReorder: (order) => reported = order,
            rowBuilder: (c, _) => SizedBox(height: _rowH, child: Text(c.id)),
            headerBuilder: (c) => SizedBox(
              height: _headerH,
              child: Text('header:${c?.id ?? 'none'}'),
            ),
          ),
        ),
      ),
    ),
  );
  final from = tester.getCenter(find.text(channel));
  final to = tester.getCenter(target) + Offset(0, targetDy);
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 400));
  const steps = 20;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
  return reported;
}

List<String>? _ids(List<ChannelOrderGroup>? groups, String? categoryId) =>
    groups
        ?.where((g) => g.categoryId == categoryId)
        .map((g) => g.channelIds)
        .firstOrNull;

void main() {
  final c1 = _cat('c1');
  final c2 = _cat('c2');
  final c3 = _cat('c3');
  List<ChannelSection> sections() => [
    (null, [_channel('a')]),
    (c1, [_channel('b'), _channel('c')]),
    (c2, [_channel('d')]),
    (c3, <Channel>[]),
  ];

  testWidgets('onto the next category header lands in that category', (
    tester,
  ) async {
    final r = await _drag(
      tester,
      sections: sections(),
      channel: 'b',
      target: find.text('header:c2'),
      targetDy: _headerH,
    );
    expect(_ids(r, 'c2'), contains('b'));
  });

  testWidgets('onto another category row lands in that category', (
    tester,
  ) async {
    final r = await _drag(
      tester,
      sections: sections(),
      channel: 'b',
      target: find.text('d'),
    );
    expect(_ids(r, 'c2'), contains('b'));
  });

  testWidgets('into an empty category', (tester) async {
    final r = await _drag(
      tester,
      sections: sections(),
      channel: 'b',
      target: find.text('header:c3'),
      targetDy: _headerH,
    );
    expect(_ids(r, 'c3'), ['b']);
  });

  testWidgets('out of uncategorised into a category', (tester) async {
    final r = await _drag(
      tester,
      sections: sections(),
      channel: 'a',
      target: find.text('c'),
    );
    expect(_ids(r, 'c1'), contains('a'));
    expect(_ids(r, null), isEmpty);
  });

  testWidgets('out of a category into uncategorised', (tester) async {
    final r = await _drag(
      tester,
      sections: sections(),
      channel: 'b',
      target: find.text('a'),
    );
    expect(_ids(r, null), contains('b'));
  });

  testWidgets('the lone channel into an empty category', (tester) async {
    final r = await _drag(
      tester,
      sections: [
        (null, [_channel('a')]),
        (c1, <Channel>[]),
      ],
      channel: 'a',
      target: find.text('header:c1'),
      targetDy: _headerH,
    );
    expect(_ids(r, 'c1'), ['a']);
  });

  testWidgets('below the last row of the last category', (tester) async {
    final r = await _drag(
      tester,
      sections: [
        (null, [_channel('a')]),
        (c1, [_channel('b')]),
        (c2, [_channel('d')]),
      ],
      channel: 'a',
      target: find.text('d'),
      targetDy: _rowH,
    );
    expect(_ids(r, 'c2'), contains('a'));
  });

  testWidgets('a phone hold lifts the lone channel into an empty category', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<ChannelOrderGroup>? reported;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReorderableChannelRows(
              sections: [
                (null, [_channel('a')]),
                (c1, <Channel>[]),
              ],
              canManage: true,
              onReorder: (order) => reported = order,
              rowBuilder: (c, _) => SizedBox(height: _rowH, child: Text(c.id)),
              headerBuilder: (c) => SizedBox(
                height: _headerH,
                child: Text('header:${c?.id ?? 'none'}'),
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.text('a')));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_ids(reported, 'c1'), ['a']);
  });
}
