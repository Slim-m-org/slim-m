// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Touch reordering of the channel rail at phone width: a finger that scrolls
/// never lifts a row, a held press lifts it, and a lifted row can be carried
/// past the fold. Drives the real `ChannelCategorySections`
/// inside a scroll view the way `ChannelRail` builds it.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/rail_drag_lift.dart';
import 'package:slimm_app/src/widgets/channel_move.dart';
import 'package:slimm_app/src/widgets/channel_rail_reorder.dart'
    show ChannelSection;
import 'package:slimm_app/src/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Channel _channel(String id, String category, int position) => Channel(
  id: id,
  name: id,
  kind: 'text',
  categoryId: category.isEmpty ? null : category,
  createdAt: 0,
  position: position,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

final _categories = [
  ChannelCategoryRow(id: 'cat-a', name: 'Alpha', position: 0),
  ChannelCategoryRow(id: 'cat-b', name: 'Beta', position: 1),
];

final _channels = [
  for (var i = 0; i < 12; i++)
    _channel('a-${i.toString().padLeft(2, '0')}', 'cat-a', i),
  for (var i = 0; i < 12; i++)
    _channel('b-${i.toString().padLeft(2, '0')}', 'cat-b', i),
];

class _Rail {
  _Rail(this.controller);
  final ScrollController controller;
  final reports = <List<api.ChannelOrderGroup>>[];
}

Future<_Rail> _pumpRail(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final rail = _Rail(ScrollController());
  addTearDown(rail.controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((_) async => http.Response('', 404)),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            controller: rail.controller,
            child: ChannelCategorySections(
              channels: _channels,
              categories: _categories,
              selectedId: null,
              canManage: true,
              onReorder: rail.reports.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return rail;
}

Finder _row(String id) => find.text(id);

Future<void> _openMenu(WidgetTester tester, String id) async {
  final gesture = await tester.startGesture(tester.getCenter(_row(id)));
  await tester.pump(kLongPressTimeout + kPressTimeout);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a finger scrolling from a row never lifts it', (tester) async {
    final rail = await _pumpRail(tester);
    final gesture = await tester.startGesture(tester.getCenter(_row('a-03')));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(rail.reports, isEmpty, reason: 'a scroll must not reorder');
    expect(rail.controller.offset, greaterThan(100), reason: 'it scrolled');
    expect(find.byType(RailDragLift), findsNothing, reason: 'nothing lifted');
  });

  testWidgets(
    'a held drag at the bottom edge scrolls the rail and drops past the fold',
    (tester) async {
      final rail = await _pumpRail(tester);
      final gesture = await tester.startGesture(tester.getCenter(_row('a-02')));
      await tester.pump(kLongPressTimeout + kPressTimeout);
      await gesture.moveBy(const Offset(0, 8));
      await tester.pump();
      final bottom = tester.view.physicalSize.height;
      await gesture.moveTo(Offset(350, bottom - 6));
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        rail.controller.offset,
        greaterThan(150),
        reason: 'edge auto-scroll',
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(rail.reports, hasLength(1));
      final beta = rail.reports.single.firstWhere(
        (g) => g.categoryId == 'cat-b',
      );
      expect(
        beta.channelIds,
        contains('a-02'),
        reason: 'reached the far category',
      );
    },
  );

  testWidgets('a still hold opens the menu and never lifts the row', (
    tester,
  ) async {
    await _pumpRail(tester);
    final gesture = await tester.startGesture(tester.getCenter(_row('a-03')));
    for (var ms = 0; ms < 1200; ms += 50) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byType(RailDragLift),
        findsNothing,
        reason: 'lifted at ${ms + 50}ms',
      );
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(RailDragLift), findsNothing);
    expect(
      find.text('Move up'),
      findsOneWidget,
      reason: 'the hold opened the menu',
    );
  });

  testWidgets('a hold then a move lifts the row and the drop reorders', (
    tester,
  ) async {
    final rail = await _pumpRail(tester);
    final start = tester.getCenter(_row('a-01'));
    final gesture = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + kPressTimeout);
    expect(
      find.byType(RailDragLift),
      findsNothing,
      reason: 'held, not yet moved',
    );
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      find.byType(RailDragLift),
      findsOneWidget,
      reason: 'the move lifted it',
    );
    await gesture.moveTo(tester.getCenter(_row('a-03')) + const Offset(0, 4));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      find.text('Move up'),
      findsNothing,
      reason: 'a drag does not open the menu',
    );
    final alpha = rail.reports.single.firstWhere(
      (g) => g.categoryId == 'cat-a',
    );
    expect(
      alpha.channelIds.indexOf('a-01'),
      greaterThan(alpha.channelIds.indexOf('a-02')),
    );
  });

  testWidgets('Move down in a row menu reports the same payload as a drag', (
    tester,
  ) async {
    final rail = await _pumpRail(tester);

    await _openMenu(tester, 'a-01');
    expect(find.text('Move up'), findsOneWidget);
    await tester.tap(find.text('Move down'));
    await tester.pumpAndSettle();

    final alpha = rail.reports.single.firstWhere(
      (g) => g.categoryId == 'cat-a',
    );
    expect(alpha.channelIds.take(3), ['a-00', 'a-02', 'a-01']);
  });

  testWidgets(
    'Move up on the first channel of a category leaves the category',
    (tester) async {
      final rail = await _pumpRail(tester);

      await _openMenu(tester, 'a-00');
      await tester.tap(find.text('Move up'));
      await tester.pumpAndSettle();

      final loose = rail.reports.single.firstWhere((g) => g.categoryId == null);
      expect(loose.channelIds, ['a-00']);
    },
  );

  group('groupsAfterStep', () {
    List<ChannelSection> sections() => [
      (null, <Channel>[]),
      (_categories[0], _channels.take(2).toList()),
      (_categories[1], _channels.skip(12).take(2).toList()),
    ];

    test('the last channel of a category steps into the start of the next', () {
      final groups = groupsAfterStep(sections(), 'a-01', 1)!;
      expect(groups[1].channelIds, ['a-00']);
      expect(groups[2].channelIds, ['a-01', 'b-00', 'b-01']);
    });

    test('the first channel steps into the end of the category above', () {
      final groups = groupsAfterStep(sections(), 'b-00', -1)!;
      expect(groups[1].channelIds, ['a-00', 'a-01', 'b-00']);
      expect(groups[2].channelIds, ['b-01']);
    });

    test('a collapsed category is stepped over', () {
      final groups = groupsAfterStep(
        sections(),
        'a-01',
        1,
        collapsed: {'cat-b'},
      );
      expect(groups, isNull, reason: 'nowhere visible to go');
    });

    test('the ends of the rail have nowhere to step', () {
      expect(groupsAfterStep(sections(), 'a-00', -1)?[0].channelIds, ['a-00']);
      expect(groupsAfterStep(sections(), 'b-01', 1), isNull);
    });
  });

  testWidgets('a phone category header has no drag grip', (tester) async {
    await _pumpRail(tester);
    expect(find.byIcon(AppIcons.dragHandle), findsNothing);
  });
}
