// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop video panel: it places the native view where its box landed,
/// hides it whenever Flutter draws over it, explains a video that cannot
/// play, and closes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/features/video/providers/docked_video.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/video/widgets/docked_video_panel.dart';
import 'package:slimm_app/src/widgets/native_view_occlusion.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../desktop/support/desktop_shell_fixture.dart';
import '../../desktop/support/fake_desktop_window_port.dart';
import 'fake_video_player.dart';

const _url = 'https://youtu.be/dQw4w9WgXcQ?t=42';
const _preview = LinkPreview(
  url: _url,
  title: 'A talk',
  authorName: 'A channel',
  videoProvider: LinkPreviewVideoProvider.youtube,
  videoId: 'dQw4w9WgXcQ',
  videoStartMs: 42000,
);

({ProviderContainer container, FakeVideoPlayer player}) _open({
  FakeDesktopWindowPort? window,
}) {
  final player = FakeVideoPlayer();
  final container = ProviderContainer(
    overrides: [
      dockedVideoPlayerFactoryProvider.overrideWithValue(() => player),
      if (window != null)
        desktopWindowShellProvider.overrideWith(
          (ref) => shellFor(window, active: true, frameless: true),
        ),
    ],
  );
  addTearDown(container.dispose);
  container.read(dockedVideoProvider.notifier).open(_url, _preview);
  return (container: container, player: player);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  DockedVideoLayout layout = DockedVideoLayout.side,
  double width = 360,
  Widget? extra,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(width: 100),
              SizedBox(
                width: width,
                height: 700,
                child: DockedVideoPanel(layout: layout),
              ),
              ?extra,
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('opening a video loads it at its start and shows its title', (
    tester,
  ) async {
    final s = _open();
    await _pump(tester, s.container);

    expect(s.player.loads.single, (
      id: 'dQw4w9WgXcQ',
      start: const Duration(seconds: 42),
    ));
    expect(find.text('A talk'), findsOneWidget);
    expect(find.text('A channel'), findsOneWidget);
  });

  testWidgets('the native view lands on the player box, at least 200 tall', (
    tester,
  ) async {
    final s = _open();
    await _pump(tester, s.container);

    final box = tester.getRect(find.byKey(DockedVideoPanel.playerKey));
    expect(box.width, 360);
    expect(box.height, kMinPlayerHeight + 2.5);
    final sent = s.player.bounds.last;
    expect(Rect.fromLTWH(sent.x, sent.y, sent.width, sent.height), box);
    expect(s.player.visible, isTrue);
  });

  testWidgets(
    'a strip caps the player by the window and keeps the 200 high floor',
    (tester) async {
      final wide = _open();
      await _pump(
        tester,
        wide.container,
        layout: DockedVideoLayout.strip,
        width: 1000,
      );
      final box = tester.getRect(find.byKey(DockedVideoPanel.playerKey));
      // 40% of the 800 high window, not the 640 wide cap.
      expect(box.size, const Size(320 * 16 / 9, 320));
      expect(box.center.dx, 100 + 500);

      final narrow = _open();
      await _pump(
        tester,
        narrow.container,
        layout: DockedVideoLayout.strip,
        width: 300,
      );
      expect(
        tester.getSize(find.byKey(DockedVideoPanel.playerKey)),
        const Size(300, kMinPlayerHeight),
      );
    },
  );

  testWidgets('an open menu hides the view until it closes', (tester) async {
    final s = _open();
    final menuOpen = ValueNotifier(false);
    addTearDown(menuOpen.dispose);
    await _pump(
      tester,
      s.container,
      extra: ValueListenableBuilder<bool>(
        valueListenable: menuOpen,
        builder: (_, open, _) => open
            ? const OccludesNativeViews(child: SizedBox(width: 10))
            : const SizedBox(width: 10),
      ),
    );
    expect(s.player.visible, isTrue);

    menuOpen.value = true;
    await tester.pump();
    expect(s.player.visible, isFalse);

    menuOpen.value = false;
    await tester.pump();
    expect(s.player.visible, isTrue);
  });

  testWidgets('a page over the shell hides the view until it pops', (
    tester,
  ) async {
    final s = _open();
    await _pump(tester, s.container);
    final navigator = tester.state<NavigatorState>(
      find.byWidgetPredicate((w) => w is Navigator),
    );

    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const Text('settings')),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(s.player.visible, isFalse);
    expect(s.player.pauses, 1, reason: 'nothing plays out of sight');

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(s.player.visible, isTrue);
  });

  testWidgets('a video its owner will not let embed says so and hides', (
    tester,
  ) async {
    final s = _open();
    await _pump(tester, s.container);

    s.player.emit(const VideoFailed(150));
    await tester.pump();
    await tester.pump();

    expect(
      find.text('This video can only be watched on YouTube.'),
      findsOneWidget,
    );
    expect(find.text('Open on YouTube'), findsOneWidget);
    expect(s.player.visible, isFalse);
  });

  testWidgets('close ends the video and disposes the player', (tester) async {
    final s = _open();
    await _pump(tester, s.container);

    await tester.tap(find.bySemanticsLabel('Close player'));
    await tester.pump();
    await tester.pump();

    expect(s.container.read(dockedVideoProvider), isNull);
    expect(s.player.disposed, isTrue);
    expect(find.text('A talk'), findsNothing);
  });

  testWidgets('a second video reuses the one player', (tester) async {
    final s = _open();
    await _pump(tester, s.container);
    s.container
        .read(dockedVideoProvider.notifier)
        .open(
          'https://youtu.be/abcdefghijk',
          const LinkPreview(
            url: 'https://youtu.be/abcdefghijk',
            title: 'Another',
            videoProvider: LinkPreviewVideoProvider.youtube,
            videoId: 'abcdefghijk',
          ),
        );
    await tester.pump();

    expect(s.player.loads.map((l) => l.id), ['dQw4w9WgXcQ', 'abcdefghijk']);
    expect(s.player.disposed, isFalse);
    expect(find.text('Another'), findsOneWidget);
  });

  testWidgets('the window follows the page into fullscreen and out of it', (
    tester,
  ) async {
    final window = FakeDesktopWindowPort();
    final s = _open(window: window);
    await _pump(tester, s.container);

    s.player.emit(const VideoFullscreenChanged(on: true));
    await tester.pump();
    expect(window.fullScreen, isTrue);

    window.emit(DesktopWindowEventKind.leaveFullScreen);
    await tester.pump();
    expect(s.player.fullscreenExits, 1, reason: 'Esc on the window');

    s.player.emit(const VideoFullscreenChanged(on: true));
    await tester.pump();
    s.container.read(dockedVideoProvider.notifier).close();
    await tester.pump();
    await tester.pump();
    expect(window.fullScreen, isFalse, reason: 'closing lets the window go');
  });
}
