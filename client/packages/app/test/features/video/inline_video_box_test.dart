// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A YouTube preview is one 16:9 box whether it shows its thumbnail, plays in
/// the message or hands over to the panel, and the player area never starts a
/// text selection in the message around it.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/features/messages/widgets/link_preview_card.dart';
import 'package:slimm_app/src/features/video/providers/desktop_video.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/video/providers/video_host_capability.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart'
    show kInlineImageMax;
import 'package:slimm_app/src/features/video/widgets/desktop_video_view.dart';
import 'package:slimm_app/src/features/video/widgets/inline_video_box.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'fake_video_player.dart';

const _url = 'https://youtu.be/dQw4w9WgXcQ';
const _proseKey = Key('prose');
const _cardKey = Key('card');

/// A 4:3 thumbnail with YouTube's black bars above and below a 16:9 picture.
Future<Uint8List> _letterboxed() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 40, 30),
    Paint()..color = Colors.black,
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 3.75, 40, 22.5),
    Paint()..color = Colors.orange,
  );
  final image = await recorder.endRecording().toImage(40, 30);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

typedef _Rig = ({FakeVideoPlayer player, ProviderContainer container});

Future<_Rig> _pump(
  WidgetTester tester, {
  required double width,
  Widget? above,
  void Function(SelectedContent?)? onSelection,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width + 40, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final player = FakeVideoPlayer();
  final bytes = (await tester.runAsync(_letterboxed))!;
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
          imageToken: 'tok',
        ),
      ),
      linkPreviewImageBytesProvider('tok').overrideWith((ref) async => bytes),
      videoHostKindProvider.overrideWith((ref) async => VideoHostKind.desktop),
      desktopVideoPlayerFactoryProvider.overrideWithValue(() => player),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(
          Brightness.light,
          AppTokens.light,
        ).copyWith(platform: TargetPlatform.linux),
        home: Scaffold(
          body: SelectionArea(
            onSelectionChanged: onSelection,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'watch https://youtu.be/dQw4w9WgXcQ today',
                      key: _proseKey,
                    ),
                    if (above != null) above,
                    const LinkPreviewCard(key: _cardKey, url: _url),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  return (player: player, container: container);
}

Finder get _card => find.byKey(_cardKey);

void main() {
  for (final width in [420.0, 520.0, 600.0, 900.0]) {
    testWidgets('the thumbnail box is 16:9 in a $width wide column', (
      tester,
    ) async {
      await _pump(tester, width: width);
      final box = tester.getSize(find.byKey(InlineVideoBox.boxKey));
      expect(box.width, lessThanOrEqualTo(kInlineImageMax));
      expect(box.width, greaterThan(356), reason: 'above the 200 floor');
      expect(box.height, closeTo(box.width * 9 / 16, 1));
    });
  }

  testWidgets('the card is as tall before play, playing and in the panel', (
    tester,
  ) async {
    final rig = await _pump(tester, width: 600);
    final before = tester.getSize(_card).height;

    await tester.tap(find.byIcon(AppIcons.play));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(find.byKey(DesktopVideoView.textureKey), findsOneWidget);
    final playing = tester.getSize(_card).height;

    rig.player.emit(const VideoPlaying());
    rig.container.read(desktopVideoProvider.notifier).scrolledAway();
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(find.text('Playing in panel'), findsOneWidget);
    final docked = tester.getSize(_card).height;

    expect(playing, before);
    expect(docked, before);
  });

  testWidgets('a double click on the player selects nothing in the message', (
    tester,
  ) async {
    final selections = <String?>[];
    await _pump(
      tester,
      width: 600,
      onSelection: (c) => selections.add(c?.plainText),
    );
    await tester.tap(find.byIcon(AppIcons.play));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    final at = tester.getCenter(find.byKey(DesktopVideoView.textureKey));
    for (var i = 0; i < 2; i++) {
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pump(const Duration(milliseconds: 500));

    expect(selections.where((s) => s != null && s.isNotEmpty), isEmpty);
  });
}
