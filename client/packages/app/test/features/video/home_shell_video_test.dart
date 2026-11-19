// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The docked video in the real shell: a third pane beside the chat where it
/// fits, with the roster under it, a strip above the chat where it does not,
/// and the same player across a channel switch until it is closed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/video/providers/docked_video.dart';
import 'package:slimm_app/src/features/video/widgets/docked_video_panel.dart';
import 'package:slimm_app/src/routing/breakpoints.dart';
import 'package:slimm_data/data.dart';

import '../settings/home_shell_harness.dart';
import 'fake_video_player.dart';

const _url = 'https://youtu.be/dQw4w9WgXcQ';
const _preview = api.LinkPreview(
  url: _url,
  title: 'A talk',
  videoProvider: api.LinkPreviewVideoProvider.youtube,
  videoId: 'dQw4w9WgXcQ',
);

typedef _Shell = ({FakeVideoPlayer player, Future<void> Function() done});

Future<_Shell> _shell(WidgetTester tester, double width) async {
  final player = FakeVideoPlayer();
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      dockedVideoPlayerFactoryProvider.overrideWithValue(() => player),
    ],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    const api.Channel(id: 'c2', name: 'random', kind: 'text', createdAt: 0),
  ]);
  await pumpAtWidth(tester, s.container, width, location: '/channels/c1');
  s.container.read(dockedVideoProvider.notifier).open(_url, _preview);
  await tester.pump();
  // Past the pane's slide in, so the box is where it rests.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
  return (player: player, done: () => teardown(tester, s.container, s.db));
}

void main() {
  testWidgets(
    'where a third pane fits, the video docks right with the roster under it',
    (tester) async {
      final s = await _shell(tester, 1400);
      final box = tester.getRect(find.byKey(DockedVideoPanel.playerKey));
      expect(box.right, 1400);
      // Full bleed inside the pane's 1px edge.
      expect(box.width, kThreadPaneWidth - 1);

      final roster = tester.getRect(find.textContaining('MEMBERS'));
      expect(roster.left, greaterThanOrEqualTo(1400 - kThreadPaneWidth));
      expect(roster.top, greaterThan(box.bottom));
      expect(find.textContaining('MEMBERS'), findsOneWidget);

      final sent = s.player.bounds.last;
      expect(Rect.fromLTWH(sent.x, sent.y, sent.width, sent.height), box);
      await s.done();
    },
  );

  testWidgets('without room for a third pane, it is a strip above the chat', (
    tester,
  ) async {
    final s = await _shell(tester, 800);
    final box = tester.getRect(find.byKey(DockedVideoPanel.playerKey));
    expect(box.width, lessThanOrEqualTo(kStripPlayerMaxWidth));
    expect(box.height, greaterThanOrEqualTo(kMinPlayerHeight));
    expect(box.left, greaterThan(0), reason: 'beside the rail, not over it');
    expect(box.bottom, lessThan(900 / 2 + 100));
    await s.done();
  });

  testWidgets('a channel switch keeps the same video playing', (tester) async {
    final s = await _shell(tester, 1400);
    final context = tester.element(find.byKey(DockedVideoPanel.playerKey));
    GoRouter.of(context).go('/channels/c2');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(DockedVideoPanel.playerKey), findsOneWidget);
    expect(s.player.loads, hasLength(1));
    expect(s.player.disposed, isFalse);
    expect(s.player.visible, isTrue);
    await s.done();
  });

  testWidgets('closing the player gives the roster its own pane back', (
    tester,
  ) async {
    final s = await _shell(tester, 1400);
    await tester.tap(find.bySemanticsLabel('Close player'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(DockedVideoPanel.playerKey), findsNothing);
    expect(s.player.disposed, isTrue);
    expect(find.textContaining('MEMBERS'), findsOneWidget);
    await s.done();
  });
}
