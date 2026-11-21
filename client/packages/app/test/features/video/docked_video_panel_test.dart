// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop video panel: it shows the player's texture in its box, sizes
/// the page to that box, forwards the pointer, pauses while a page covers
/// it, explains a video that cannot play, and closes.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/features/video/providers/desktop_video.dart';
import 'package:slimm_app/src/features/video/providers/desktop_video_player.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/video/widgets/docked_video_panel.dart';
import 'package:slimm_app/src/features/video/widgets/desktop_video_view.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../desktop/support/desktop_shell_fixture.dart';
import '../../desktop/support/fake_desktop_window_port.dart';
import 'fake_video_player.dart';

const _field = Key('field');
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
      desktopVideoPlayerFactoryProvider.overrideWithValue(() => player),
      if (window != null)
        desktopWindowShellProvider.overrideWith(
          (ref) => shellFor(window, active: true, frameless: true),
        ),
    ],
  );
  addTearDown(container.dispose);
  final message = Object();
  container.read(desktopVideoProvider.notifier)
    ..playIn(message, _url, _preview)
    ..leave(message);
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

  testWidgets('the texture fills the player box, at least 200 tall', (
    tester,
  ) async {
    final s = _open();
    await _pump(tester, s.container);

    final box = tester.getRect(find.byKey(DockedVideoPanel.playerKey));
    expect(box.width, 360);
    expect(box.height, kMinPlayerHeight + 2.5);
    expect(tester.getRect(find.byKey(DesktopVideoView.textureKey)), box);
    expect(
      tester.widget<Texture>(find.byKey(DesktopVideoView.textureKey)).textureId,
      FakeVideoPlayer.textureId,
    );
    expect(s.player.sizes.last, (box.size, 1.0));
  });

  testWidgets('the pointer reaches the page at its spot in the box', (
    tester,
  ) async {
    final s = _open();
    await _pump(tester, s.container);
    final box = tester.getRect(find.byKey(DockedVideoPanel.playerKey));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(box.topLeft + const Offset(30, 40));
    await mouse.down(box.topLeft + const Offset(30, 40));
    await mouse.moveTo(box.topLeft + const Offset(90, 40));
    await mouse.up();
    await mouse.moveTo(Offset.zero);
    await tester.pump();

    expect(s.player.pointers.take(5), [
      (VideoPointerKind.enter, const Offset(30, 40)),
      (VideoPointerKind.move, const Offset(30, 40)),
      (VideoPointerKind.down, const Offset(30, 40)),
      (VideoPointerKind.move, const Offset(90, 40)),
      (VideoPointerKind.up, const Offset(90, 40)),
    ]);
    expect(s.player.pointers.last.$1, VideoPointerKind.leave);
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

  testWidgets(
    'after a click on the player, a field takes the keyboard again',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      final s = _open();
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await _pump(
        tester,
        s.container,
        extra: SizedBox(
          width: 200,
          child: TextField(key: _field, focusNode: focus),
        ),
      );
      await tester.tap(find.byKey(_field), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.tap(
        find.byKey(DesktopVideoView.textureKey),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.context?.widget,
        isNot(isA<Texture>()),
        reason: 'the player holds no Flutter focus, so keys never go to it',
      );
      await tester.tap(find.byKey(_field), kind: PointerDeviceKind.mouse);
      await tester.pump();

      expect(focus.hasFocus, isTrue);
      expect(
        s.player.pointers.map((p) => p.$1),
        contains(VideoPointerKind.down),
      );
    },
  );

  testWidgets('a page over the shell pauses the video and resizes on return', (
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
    expect(s.player.pauses, 1, reason: 'nothing plays out of sight');
    final sent = s.player.sizes.length;

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(s.player.sizes.length, sent + 1, reason: 'in front again');
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
    expect(find.byKey(DesktopVideoView.textureKey), findsNothing);
  });

  testWidgets('close ends the video and disposes the player', (tester) async {
    final s = _open();
    await _pump(tester, s.container);

    await tester.tap(find.bySemanticsLabel('Close player'));
    await tester.pump();
    await tester.pump();

    expect(s.container.read(desktopVideoProvider), isNull);
    expect(s.player.disposed, isTrue);
    expect(find.text('A talk'), findsNothing);
  });

  testWidgets('a second video reuses the one player', (tester) async {
    final s = _open();
    await _pump(tester, s.container);
    final message = Object();
    s.container.read(desktopVideoProvider.notifier)
      ..playIn(
        message,
        'https://youtu.be/abcdefghijk',
        const LinkPreview(
          url: 'https://youtu.be/abcdefghijk',
          title: 'Another',
          videoProvider: LinkPreviewVideoProvider.youtube,
          videoId: 'abcdefghijk',
        ),
      )
      ..leave(message);
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
    s.container.read(desktopVideoProvider.notifier).close();
    await tester.pump();
    await tester.pump();
    expect(window.fullScreen, isFalse, reason: 'closing lets the window go');
  });
}
