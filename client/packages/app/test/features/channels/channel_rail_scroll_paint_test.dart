// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Scrolling a long rail repaints no row: the rows are one retained layer the scroll only moves.
/// A break-it tester measured 33 ms rail frames at about 75 channels, twice the message pane's.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../ui_snapshot_support.dart';

const _channelCount = 75;
const _scrollFrames = 30;

Future<({ProviderContainer container, SlimmDatabase db})> _pumpLongRail(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer();
  await tester.runAsync(() async {
    final store = await fixture.container.read(storeProvider.future);
    await store.upsertChannels([
      for (var i = 0; i < _channelCount; i++)
        api.Channel(
          id: 'c-scale-$i',
          name: 'scale-${i.toString().padLeft(3, '0')}',
          kind: i.isEven ? 'text' : 'voice',
          createdAt: 0,
          position: 100 + i,
        ),
    ]);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: GoRouter(
          initialLocation: Routes.channel('c-general'),
          routes: [
            GoRoute(
              path: Routes.channelPattern,
              builder: (context, state) => const Scaffold(
                body: Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(width: 248, child: ChannelRail()),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  // Drift answers in real time and the tree on the fake clock, so each gets its turn.
  for (var i = 0; i < 100 && find.text('scale-074').evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(find.text('scale-074'), findsOneWidget);
  await pumpFrames(tester);
  return fixture;
}

void main() {
  testWidgets('a scroll frame in a long rail paints no channel row', (
    tester,
  ) async {
    final fixture = await _pumpLongRail(tester);
    final position = tester
        .stateList<ScrollableState>(
          find.byWidgetPredicate((w) => w is Scrollable),
        )
        .map((s) => s.position)
        .reduce((a, b) => a.maxScrollExtent >= b.maxScrollExtent ? a : b);
    expect(
      position.maxScrollExtent,
      greaterThan(1000),
      reason: 'the fixture must overflow the rail or a scroll proves nothing',
    );

    var painted = 0;
    debugOnProfilePaint = (_) => painted++;
    final watch = Stopwatch()..start();
    for (var i = 1; i <= _scrollFrames; i++) {
      position.jumpTo(position.maxScrollExtent * i / _scrollFrames);
      await tester.pump(const Duration(milliseconds: 16));
    }
    watch.stop();
    debugOnProfilePaint = null;
    final perFrame = painted / _scrollFrames;
    printOnFailure(
      'rail scroll: ${perFrame.toStringAsFixed(1)} render objects painted and '
      '${(watch.elapsedMicroseconds / _scrollFrames / 1000).toStringAsFixed(2)} '
      'ms per frame',
    );

    expect(
      perFrame,
      lessThan(20),
      reason:
          'a scroll frame re-painted $perFrame render objects; the rows '
          'should be a retained layer the viewport only moves',
    );
    await teardownFixture(tester, fixture.container, fixture.db);
  });
}
