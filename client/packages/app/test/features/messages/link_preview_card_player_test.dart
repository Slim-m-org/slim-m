// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a tapped YouTube preview plays: in place on a phone or through the
/// desktop's shared player, or in the browser where neither exists.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/features/messages/widgets/link_preview_card.dart';
import 'package:slimm_app/src/features/video/providers/desktop_video.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/video/providers/inline_video_player.dart';
import 'package:slimm_app/src/features/video/providers/video_host_capability.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/video/widgets/desktop_video_view.dart';
import 'package:slimm_design_system/design_system.dart';

import '../video/fake_video_player.dart';

const _url = 'https://youtu.be/dQw4w9WgXcQ?t=42';
const _inlineView = Key('fake-inline-view');
const _launcher = MethodChannel('plugins.flutter.io/url_launcher');

class _Harness {
  final player = FakeVideoPlayer();
  final launched = <String>[];
  late final ProviderContainer container;
}

Future<_Harness> _pump(WidgetTester tester, VideoHostKind host) async {
  SharedPreferences.setMockInitialValues({});
  final h = _Harness();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_launcher, (
    call,
  ) async {
    if (call.method == 'launch') {
      h.launched.add((call.arguments as Map)['url'] as String);
    }
    return true;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _launcher,
      null,
    ),
  );
  h.container = ProviderContainer(
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
          videoStartMs: 42000,
        ),
      ),
      videoHostKindProvider.overrideWith((ref) async => host),
      desktopVideoPlayerFactoryProvider.overrideWithValue(() => h.player),
      inlineVideoFactoryProvider.overrideWithValue(
        ({required onShowFullscreen, required onHideFullscreen}) => (
          player: h.player,
          view: const ColoredBox(key: _inlineView, color: Colors.black),
        ),
      ),
    ],
  );
  addTearDown(h.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: LinkPreviewCard(url: _url)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return h;
}

Future<void> _tapPlay(WidgetTester tester) async {
  await tester.tap(find.byIcon(AppIcons.play));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('on a phone the video plays in place, from its start', (
    tester,
  ) async {
    final h = await _pump(tester, VideoHostKind.inline);
    await _tapPlay(tester);

    expect(find.byKey(_inlineView), findsOneWidget);
    expect(find.byIcon(AppIcons.play), findsNothing);
    expect(h.player.loads.single, (
      id: 'dQw4w9WgXcQ',
      start: const Duration(seconds: 42),
    ));
    expect(h.launched, isEmpty);
  });

  testWidgets('a phone player at least meets YouTube\'s 200 high floor', (
    tester,
  ) async {
    await _pump(tester, VideoHostKind.inline);
    await _tapPlay(tester);
    expect(
      tester.getSize(find.byKey(_inlineView)).height,
      greaterThanOrEqualTo(200),
    );
  });

  testWidgets('a phone player that cannot embed offers YouTube instead', (
    tester,
  ) async {
    final h = await _pump(tester, VideoHostKind.inline);
    await _tapPlay(tester);
    h.player.emit(const VideoFailed(101));
    await tester.pump();

    expect(
      find.text('This video can only be watched on YouTube.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Open on YouTube'));
    await tester.pump();
    expect(h.launched, [_url]);
  });

  testWidgets('leaving the message disposes the phone player', (tester) async {
    final h = await _pump(tester, VideoHostKind.inline);
    await _tapPlay(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(h.player.disposed, isTrue);
  });

  testWidgets('on desktop the video plays in place through the one player', (
    tester,
  ) async {
    final h = await _pump(tester, VideoHostKind.desktop);
    await _tapPlay(tester);

    final video = h.container.read(desktopVideoProvider);
    expect(video?.url, _url);
    expect(video?.start, const Duration(seconds: 42));
    expect(video?.docked, isFalse);
    expect(find.byKey(DesktopVideoView.textureKey), findsOneWidget);
    expect(find.byIcon(AppIcons.play), findsNothing);
    expect(h.player.loads, hasLength(1));
    expect(h.launched, isEmpty);
  });

  testWidgets('a desktop video playing on in the panel comes back on a tap', (
    tester,
  ) async {
    final h = await _pump(tester, VideoHostKind.desktop);
    await _tapPlay(tester);
    final controller = h.container.read(desktopVideoProvider.notifier);
    controller.scrolledAway();
    await tester.pump();

    expect(h.container.read(desktopVideoProvider)?.docked, isTrue);
    expect(find.text('Playing in panel'), findsOneWidget);
    expect(find.byKey(DesktopVideoView.textureKey), findsNothing);

    await tester.tap(find.text('Playing in panel'));
    await tester.pump();
    expect(h.container.read(desktopVideoProvider)?.docked, isFalse);
    expect(find.byKey(DesktopVideoView.textureKey), findsOneWidget);
    expect(h.player.loads, hasLength(1), reason: 'it moves, never restarts');

    controller.close();
    await tester.pump();
    expect(find.text('Playing in panel'), findsNothing);
    expect(find.byIcon(AppIcons.play), findsOneWidget);
  });

  testWidgets('without a player here the video opens in the browser', (
    tester,
  ) async {
    final h = await _pump(tester, VideoHostKind.external);
    await _tapPlay(tester);

    expect(h.launched, [_url]);
    expect(h.container.read(desktopVideoProvider), isNull);
    expect(find.byKey(_inlineView), findsNothing);
    expect(find.byIcon(AppIcons.play), findsOneWidget);
  });
}
