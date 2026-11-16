// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real rail sections drawing a two-level tree (decision 0120): the
/// owner's "gamers/{minecraft, cs2}" example, folding at both levels, and a
/// cs-only member who is shown gamers as a heading over cs2 alone.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/channels/providers/collapsed_categories_preference.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_reorder.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_section_label.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_drag_lift.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Channel _channel(String id, String categoryId, {int cursor = 0}) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: cursor,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: categoryId,
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

class _Settled extends ChannelNotificationOverridesController {
  _Settled(super.ref) {
    state = const ChannelNotificationOverridesState(
      byChannel: {},
      settled: true,
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required List<Channel> channels,
  required List<ChannelCategoryRow> categories,
  Set<String> collapsed = const {},
  bool canManage = false,
}) async {
  SharedPreferences.setMockInitialValues({
    if (collapsed.isNotEmpty) collapsedCategoriesKey: collapsed.toList(),
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      channelNotificationOverridesProvider.overrideWith(_Settled.new),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChannelCategorySections(
              channels: channels,
              categories: categories,
              selectedId: null,
              canManage: canManage,
              onReorder: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
}

bool _shown(String text) => find.text(text).evaluate().isNotEmpty;

double _left(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dx;

/// Whether an unread dot sits on the same line as the [header] text.
bool _dotBeside(WidgetTester tester, String header) {
  final line = tester.getRect(find.text(header));
  return find.byKey(AppListRow.unreadDotKey).evaluate().any((e) {
    final box = e.renderObject! as RenderBox;
    final y = box.localToGlobal(box.size.center(Offset.zero)).dy;
    return y >= line.top && y <= line.bottom;
  });
}

bool _addRevealed(WidgetTester tester, String categoryId) => tester
    .widget<AddChannelGlyph>(
      find.byWidgetPredicate(
        (w) => w is AddChannelGlyph && w.categoryId == categoryId,
      ),
    )
    .revealed;

final _all = [
  _channel('lobby', 'gamers'),
  _channel('survival', 'minecraft'),
  _channel('matchmaking', 'cs2'),
];

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('a sub-category hangs one step in from its parent at '
        '$width wide', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        channels: _all,
        categories: const [_gamers, _minecraft, _cs2],
      );

      expect(
        _left(tester, 'cs2') - _left(tester, 'gamers'),
        closeTo(kRailRowInset, 0.5),
      );
      expect(_left(tester, 'minecraft'), closeTo(_left(tester, 'cs2'), 0.5));
      expect(
        _left(tester, 'matchmaking') - _left(tester, 'lobby'),
        closeTo(kRailRowInset, 0.5),
      );
      final order = [
        for (final t in [
          'lobby',
          'minecraft',
          'survival',
          'cs2',
          'matchmaking',
        ])
          tester.getTopLeft(find.text(t)).dy,
      ];
      expect(order, [...order]..sort(), reason: 'own channels, then subs');
    });
  }

  testWidgets('a cs-only member is shown gamers as a heading over cs2 alone', (
    tester,
  ) async {
    await _pump(
      tester,
      channels: [_channel('matchmaking', 'cs2')],
      categories: const [_gamers, _cs2],
    );

    expect(_shown('gamers'), isTrue);
    expect(_shown('cs2'), isTrue);
    expect(_shown('matchmaking'), isTrue);
    expect(_shown('lobby'), isFalse);
    expect(_shown('minecraft'), isFalse);
    expect(
      tester.getTopLeft(find.text('gamers')).dy,
      lessThan(tester.getTopLeft(find.text('cs2')).dy),
    );
  });

  testWidgets('folding the parent hides its sub-categories and rolls their '
      'unread up into its own dot', (tester) async {
    await _pump(
      tester,
      channels: [
        _channel('lobby', 'gamers'),
        _channel('survival', 'minecraft'),
        _channel('matchmaking', 'cs2', cursor: 3),
      ],
      categories: const [_gamers, _minecraft, _cs2],
      collapsed: {'gamers'},
    );

    expect(_shown('lobby'), isFalse);
    expect(_shown('minecraft'), isFalse);
    expect(_shown('survival'), isFalse);
    expect(_dotBeside(tester, 'gamers'), isTrue);
    expect(
      _shown('matchmaking'),
      isTrue,
      reason: 'an unread row still surfaces under the fold',
    );
    expect(
      _shown('cs2'),
      isTrue,
      reason: 'beneath its own sub-category heading',
    );
  });

  testWidgets('a folded sub-category keeps its own state under an open '
      'parent', (tester) async {
    await _pump(
      tester,
      channels: [
        _channel('lobby', 'gamers'),
        _channel('survival', 'minecraft', cursor: 2),
        _channel('matchmaking', 'cs2'),
      ],
      categories: const [_gamers, _minecraft, _cs2],
      collapsed: {'cs2', 'minecraft'},
    );

    expect(_shown('lobby'), isTrue);
    expect(_shown('cs2'), isTrue);
    expect(_shown('matchmaking'), isFalse);
    expect(_dotBeside(tester, 'minecraft'), isTrue);
    expect(_dotBeside(tester, 'cs2'), isFalse);
    expect(_dotBeside(tester, 'gamers'), isFalse, reason: 'it is open');
  });

  testWidgets('under a folded parent a surfaced sub-heading reads folded, and '
      'pressing it opens the parent and itself', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      channels: [
        _channel('lobby', 'gamers'),
        _channel('ranked', 'cs2'),
        _channel('matchmaking', 'cs2', cursor: 3),
      ],
      categories: const [_gamers, _cs2],
      collapsed: {'gamers'},
    );

    expect(tester.getSemantics(find.bySemanticsLabel('cs2')).hint, 'Expand');
    expect(_shown('ranked'), isFalse);
    await tester.tap(find.text('cs2'));
    await pumpFrames(tester);

    expect(_shown('lobby') && _shown('ranked'), isTrue);
    expect(tester.getSemantics(find.bySemanticsLabel('cs2')).hint, 'Collapse');
    semantics.dispose();
  });

  testWidgets('a folded header puts its dot on the rows dot column for a '
      'manager at pointer width', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      channels: [
        _channel('lobby', 'gamers'),
        _channel('matchmaking', 'cs2', cursor: 3),
      ],
      categories: const [_gamers, _cs2],
      collapsed: {'gamers'},
      canManage: true,
    );

    final dots = [
      for (final e in find.byKey(AppListRow.unreadDotKey).evaluate())
        (e.renderObject! as RenderBox).localToGlobal(
          (e.renderObject! as RenderBox).size.center(Offset.zero),
        ),
    ];
    expect(dots, hasLength(2), reason: 'the header and the surfaced row');
    expect(dots.first.dx, closeTo(dots.last.dx, 0.5));
  });

  testWidgets('at pointer width a sub-category header reveals its + on hover '
      'and lifts on a held press, as a top-level one does', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      channels: _all,
      categories: const [_gamers, _minecraft, _cs2],
      canManage: true,
    );
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(hover.removePointer);

    for (final (hovered, other) in [('cs2', 'gamers'), ('gamers', 'cs2')]) {
      await hover.moveTo(tester.getCenter(find.text(hovered)));
      await pumpFrames(tester);
      expect(_addRevealed(tester, hovered), isTrue, reason: hovered);
      expect(_addRevealed(tester, other), isFalse, reason: hovered);
    }
    expect(
      tester
          .getRect(find.bySemanticsLabel('Create a channel in gamers / cs2'))
          .right,
      closeTo(
        tester
            .getRect(find.bySemanticsLabel('Create a channel in gamers'))
            .right,
        0.5,
      ),
    );

    final start = tester.getCenter(find.text('cs2'));
    final press = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await press.moveTo(start + const Offset(0, 24));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      find.byWidgetPredicate((w) => w is RailDragLift),
      findsOneWidget,
      reason: 'the held sub-category is carried',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await press.up();
    await pumpFrames(tester);
  });
}
