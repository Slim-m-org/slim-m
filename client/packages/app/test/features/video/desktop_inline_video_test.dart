// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop player in place in a scrolling conversation: it fills the
/// thumbnail's box, scrolls and clips with the list, and when its message
/// leaves (scrolled out of sight, or gone with a channel switch) a playing
/// video moves on to the panel while a paused one closes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart'
    show kInlineImageMax;
import 'package:slimm_app/src/features/messages/widgets/link_preview_card.dart';
import 'package:slimm_app/src/features/video/providers/desktop_video.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/video/providers/video_host_capability.dart';
import 'package:slimm_app/src/features/video/widgets/docked_video_panel.dart'
    show kMinPlayerHeight;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/video/widgets/desktop_video_view.dart';
import 'package:slimm_design_system/design_system.dart';

import 'fake_video_player.dart';

const _url = 'https://youtu.be/dQw4w9WgXcQ';
const _filler = 600.0;

typedef _Chat = ({
  FakeVideoPlayer player,
  ProviderContainer container,
  ScrollController scroll,
  ValueNotifier<bool> showCard,
});

Future<_Chat> _chat(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final player = FakeVideoPlayer();
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      linkPreviewProvider(_url).overrideWith(
        (ref) async => const LinkPreview(
          url: _url,
          title: 'A talk',
          videoProvider: LinkPreviewVideoProvider.youtube,
          videoId: 'dQw4w9WgXcQ',
        ),
      ),
      videoHostKindProvider.overrideWith((ref) async => VideoHostKind.desktop),
      desktopVideoPlayerFactoryProvider.overrideWithValue(() => player),
    ],
  );
  addTearDown(container.dispose);
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  final showCard = ValueNotifier(true);
  addTearDown(showCard.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: showCard,
            builder: (_, show, _) => ListView(
              controller: scroll,
              children: [
                const SizedBox(height: _filler),
                if (show) const LinkPreviewCard(url: _url),
                const SizedBox(height: _filler),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  scroll.jumpTo(_filler - 100);
  await tester.pump();
  await tester.tap(find.byIcon(AppIcons.play));
  await tester.pump();
  await tester.pump();
  return (
    player: player,
    container: container,
    scroll: scroll,
    showCard: showCard,
  );
}

Rect _player(WidgetTester tester) =>
    tester.getRect(find.byKey(DesktopVideoView.textureKey));

Future<void> _scrollTo(WidgetTester tester, _Chat c, double offset) async {
  c.scroll.jumpTo(offset);
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('it fills the thumbnail\'s box and sizes the page to it', (
    tester,
  ) async {
    final c = await _chat(tester);
    final box = _player(tester);

    expect(box.width, kInlineImageMax);
    expect(box.height, kInlineImageMax * 9 / 16);
    expect(box.height, greaterThanOrEqualTo(kMinPlayerHeight));
    expect(box.top, greaterThan(100), reason: 'inside its message card');
    expect(c.player.size, box.size);
    expect(c.container.read(desktopVideoProvider)?.docked, isFalse);
  });

  testWidgets('it scrolls with the chat and stays put while partly in sight', (
    tester,
  ) async {
    final c = await _chat(tester);
    final before = _player(tester);

    await _scrollTo(tester, c, _filler - 100 + before.bottom - 40);
    final after = _player(tester);
    expect(after.top, before.top - (before.bottom - 40));
    expect(after.bottom, 40, reason: 'only its bottom 40 still in sight');
    expect(after.top, lessThan(0), reason: 'the list clips the rest');
    expect(c.container.read(desktopVideoProvider)?.docked, isFalse);
    expect(c.player.pauses, 0);
  });

  testWidgets('scrolled wholly out of sight, a playing video docks', (
    tester,
  ) async {
    final c = await _chat(tester);
    c.player.emit(const VideoPlaying());
    final box = _player(tester);

    await _scrollTo(tester, c, _filler - 100 + box.bottom + 20);

    expect(c.container.read(desktopVideoProvider)?.docked, isTrue);
    expect(find.byKey(DesktopVideoView.textureKey), findsNothing);
    expect(find.text('Playing in panel', skipOffstage: false), findsOneWidget);
    expect(c.player.disposed, isFalse);
    expect(c.player.loads, hasLength(1));
  });

  testWidgets('scrolled out of sight, a paused video closes', (tester) async {
    final c = await _chat(tester);
    c.player.emit(const VideoPaused());
    final box = _player(tester);

    await _scrollTo(tester, c, _filler - 100 + box.bottom + 20);

    expect(c.container.read(desktopVideoProvider), isNull);
    expect(c.player.disposed, isTrue);
  });

  testWidgets('a message that goes (a channel switch) hands the video on', (
    tester,
  ) async {
    final c = await _chat(tester);
    c.player.emit(const VideoBuffering());

    c.showCard.value = false;
    await tester.pump();
    await tester.pump();

    expect(c.container.read(desktopVideoProvider)?.docked, isTrue);
    expect(c.player.disposed, isFalse);
  });
}
