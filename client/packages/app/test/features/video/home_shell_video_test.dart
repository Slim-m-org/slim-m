// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The docked video in the real shell: a third pane beside the chat where it
/// fits, with the roster under it, a strip above the chat where it does not,
/// and the same player across a channel switch until it is closed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_open.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/video/providers/docked_video.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/video/widgets/docked_video_panel.dart';
import 'package:slimm_app/src/routing/breakpoints.dart';
import 'package:slimm_data/data.dart';

import '../../desktop/support/desktop_shell_fixture.dart';
import '../../desktop/support/fake_desktop_window_port.dart';
import '../settings/home_shell_harness.dart';
import 'fake_video_player.dart';

const _url = 'https://youtu.be/dQw4w9WgXcQ';
const _preview = api.LinkPreview(
  url: _url,
  title: 'A talk',
  videoProvider: api.LinkPreviewVideoProvider.youtube,
  videoId: 'dQw4w9WgXcQ',
);

typedef _Shell = ({
  FakeVideoPlayer player,
  ProviderContainer container,
  Future<void> Function() done,
});

Future<_Shell> _shell(
  WidgetTester tester,
  double width, {
  FakeDesktopWindowPort? window,
}) async {
  final player = FakeVideoPlayer();
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      dockedVideoPlayerFactoryProvider.overrideWithValue(() => player),
      if (window != null)
        desktopWindowShellProvider.overrideWith(
          (ref) => shellFor(window, active: true, frameless: true),
        ),
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
  return (
    player: player,
    container: s.container,
    done: () => teardown(tester, s.container, s.db),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

ScaffoldState _shellScaffold(WidgetTester tester) =>
    Scaffold.of(tester.element(find.byKey(DockedVideoPanel.playerKey)));

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

  testWidgets('the roster drawer over the strip hides the view', (
    tester,
  ) async {
    final s = await _shell(tester, 800);
    expect(s.player.visible, isTrue);

    _shellScaffold(tester).openEndDrawer();
    await _settle(tester);
    expect(s.player.visible, isFalse);

    _shellScaffold(tester).closeEndDrawer();
    await _settle(tester);
    expect(s.player.visible, isTrue);
    await s.done();
  });

  testWidgets('both compact drawers hide the view while open', (tester) async {
    final s = await _shell(tester, 500);
    expect(s.player.visible, isTrue);

    _shellScaffold(tester).openDrawer();
    await _settle(tester);
    expect(s.player.visible, isFalse, reason: 'the channel rail drawer');
    _shellScaffold(tester).closeDrawer();
    await _settle(tester);
    expect(s.player.visible, isTrue);

    _shellScaffold(tester).openEndDrawer();
    await _settle(tester);
    expect(s.player.visible, isFalse, reason: 'the roster drawer');
    await s.done();
  });

  testWidgets('back to the compact channel list pauses the hidden video', (
    tester,
  ) async {
    final s = await _shell(tester, 500);
    final context = tester.element(find.byKey(DockedVideoPanel.playerKey));
    GoRouter.of(context).go('/channels');
    await _settle(tester);

    expect(find.byKey(DockedVideoPanel.playerKey), findsNothing);
    expect(s.player.visible, isFalse);
    expect(s.player.pauses, greaterThan(0));
    await s.done();
  });

  testWidgets('a fullscreen canvas takes the whole pane and pauses the video', (
    tester,
  ) async {
    final s = await _shell(tester, 1400);
    s.container.read(canvasOpenProvider.notifier).state = 'c1';
    s.container.read(canvasFullscreenProvider.notifier).state = 'c1';
    await _settle(tester);

    expect(find.byKey(DockedVideoPanel.playerKey), findsNothing);
    expect(s.player.pauses, greaterThan(0));
    await s.done();
  });

  testWidgets('the strip is reachable by a screen reader', (tester) async {
    final s = await _shell(tester, 800);
    await tester.tap(find.bySemanticsLabel('Close player'));
    await tester.pump();
    await tester.pump();

    expect(s.player.disposed, isTrue);
    await s.done();
  });

  testWidgets(
    'fullscreen started from the strip survives the wider window it makes',
    (tester) async {
      final window = FakeDesktopWindowPort();
      final s = await _shell(tester, 800, window: window);
      s.player.emit(const VideoFullscreenChanged(on: true));
      await tester.pump();
      expect(window.fullScreen, isTrue);

      tester.view.physicalSize = const Size(1920, 1080);
      await _settle(tester);
      expect(
        tester.getRect(find.byKey(DockedVideoPanel.playerKey)).right,
        1920,
        reason: 'the wider window docks it beside the chat',
      );
      expect(window.fullScreen, isTrue);
      expect(s.player.fullscreenExits, 0);

      s.player.emit(const VideoFullscreenChanged(on: false));
      await _settle(tester);
      expect(window.fullScreen, isFalse);
      await s.done();
    },
  );
}
