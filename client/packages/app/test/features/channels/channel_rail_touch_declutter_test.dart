// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel rail at phone width reads as a list, not a toolbar: a row is
/// its kind icon, name and badge, a category header is a chevron and a name,
/// and everything else lives behind a long press (`desktop-vs-mobile.md`
/// rules 1 and 3). The 1280 cases pin that the pointer layout is unchanged.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_channel_rows.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_drag_lift.dart';
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
  categoryId: category,
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
  const ChannelCategoryRow(id: 'cat-a', name: 'Alpha', position: 0),
  const ChannelCategoryRow(id: 'cat-b', name: 'Beta', position: 1),
];

final _channels = [
  for (var i = 0; i < 3; i++) _channel('a-$i', 'cat-a', i),
  for (var i = 0; i < 3; i++) _channel('b-$i', 'cat-b', i),
];

Future<List<List<api.ChannelOrderGroup>>> _pumpRail(
  WidgetTester tester,
  double width,
) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final reports = <List<api.ChannelOrderGroup>>[];
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
            child: ChannelCategorySections(
              channels: _channels,
              categories: _categories,
              selectedId: null,
              canManage: true,
              onReorder: reports.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return reports;
}

List<String> _menuLabels(WidgetTester tester) => [
  for (final item in tester.widgetList<AppMenuItem>(find.byType(AppMenuItem)))
    item.label,
];

Future<void> _liftAndRelease(WidgetTester tester, Finder row) async {
  final gesture = await tester.startGesture(tester.getCenter(row));
  await tester.pump(kLongPressTimeout + kPressTimeout);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a phone row shows no grip and no kebab', (tester) async {
    await _pumpRail(tester, 390);
    expect(find.byIcon(AppIcons.moreVertical), findsNothing);
    expect(find.byIcon(AppIcons.dragHandle), findsNothing);
  });

  testWidgets('a phone category header is a chevron, a name and a plus', (
    tester,
  ) async {
    await _pumpRail(tester, 390);
    expect(find.byIcon(AppIcons.chevronDown), findsNWidgets(2));
    expect(find.byIcon(AppIcons.add), findsNWidgets(2));
  });

  testWidgets('a header sits closer to its rows than to the category above', (
    tester,
  ) async {
    await _pumpRail(tester, 390);
    double mid(String text) => tester.getCenter(find.text(text)).dy;
    final headerToFirst = mid('a-0') - mid('Alpha');
    final lastToNextHeader = mid('Beta') - mid('a-2');
    expect(
      headerToFirst,
      lessThanOrEqualTo(40),
      reason: 'header text to first row text, was 50',
    );
    expect(
      lastToNextHeader,
      greaterThan(headerToFirst),
      reason: 'categories stay visibly separate',
    );
    for (final id in ['a-0', 'a-1', 'a-2', 'b-0']) {
      final row = find.ancestor(
        of: find.text(id),
        matching: find.byType(AppListRow),
      );
      expect(tester.getSize(row).height, greaterThanOrEqualTo(44));
    }
  });

  testWidgets('a held press on a phone row lifts it and opens its sheet', (
    tester,
  ) async {
    final reports = await _pumpRail(tester, 390);
    await _liftAndRelease(tester, find.text('a-1'));
    expect(reports, isEmpty, reason: 'released in place moves nothing');
    expect(find.text('Channel settings...'), findsOneWidget);
    expect(find.text('Move up'), findsOneWidget);
  });

  testWidgets('a held press on a header opens the category sheet', (
    tester,
  ) async {
    await _pumpRail(tester, 390);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Alpha')),
    );
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Rename category...'), findsOneWidget);
    expect(find.text('Move category down'), findsOneWidget);
  });

  testWidgets('the phone sheet offers the same items as the desktop kebab', (
    tester,
  ) async {
    await _pumpRail(tester, 1280);
    await tester.tap(find.byIcon(AppIcons.moreVertical).at(1));
    await tester.pumpAndSettle();
    final kebabItems = _menuLabels(tester);
    expect(kebabItems, contains('Channel settings...'));
    await tester.pumpWidget(const SizedBox());

    await _pumpRail(tester, 390);
    await _liftAndRelease(tester, find.text('a-1'));
    expect(_menuLabels(tester), kebabItems);
  });

  testWidgets('a phone row stays reachable by a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpRail(tester, 390);
    final row = find.ancestor(
      of: find.text('a-1'),
      matching: find.byType(ManagedChannelRow),
    );
    final data = tester.getSemantics(row).getSemanticsData();
    expect(data.hasAction(SemanticsAction.longPress), isTrue);
    expect(data.customSemanticsActionIds, isNotEmpty, reason: 'move up/down');
    handle.dispose();
  });

  testWidgets('a desktop row keeps its hover kebab and shows no grip', (
    tester,
  ) async {
    await _pumpRail(tester, 1280);
    expect(find.byIcon(AppIcons.moreVertical), findsNWidgets(6));
    expect(find.byIcon(AppIcons.dragHandle), findsNothing);
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byIcon(AppIcons.moreVertical).at(1),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;
    expect(opacity(), 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('a-1')));
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    expect(find.byIcon(AppIcons.dragHandle), findsNothing, reason: 'on hover');
  });

  testWidgets('a desktop hold released in place opens no menu and no sheet', (
    tester,
  ) async {
    final reports = await _pumpRail(tester, 1280);
    final at = tester.getCenter(find.text('a-1'));
    final gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RailDragLift), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(AppMenuItem), findsNothing);
    expect(find.byType(RailDragLift), findsNothing);
    expect(reports, isEmpty);
  });
}
