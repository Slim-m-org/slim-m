// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When an inline video row builds its player, and who keeps it alive: a row
/// nobody has seen constructs none, and a fullscreen route holds the player
/// until it pops even if the row it came from unmounts first.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_video_player.dart';
import 'package:slimm_design_system/design_system.dart';

import 'attachment_video_fakes.dart';

void main() {
  setUpAll(MediaKit.ensureInitialized);

  final media = Media('http://localhost:1/clip.mp4');

  testWidgets('a row nobody has seen constructs no player', (tester) async {
    var players = 0;
    final player = FakePlayer();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWithValue(
            api.SlimmApi(baseUrl: Uri.parse('http://localhost:1')),
          ),
          attachmentVideoSourceProvider.overrideWithValue(
            () => ScriptedSource([media]),
          ),
          attachmentPlayerProvider.overrideWithValue(() {
            players += 1;
            return player;
          }),
          attachmentVideoControllerProvider.overrideWithValue(
            (_) => FakeVideoController(),
          ),
          attachmentVideoSurfaceProvider.overrideWithValue(
            (player, controller, onToggleFullscreen, onSave, saving) =>
                const SizedBox(key: Key('ready-surface')),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ListView(
              controller: controller,
              scrollCacheExtent: const ScrollCacheExtent.pixels(3000),
              children: const [
                SizedBox(height: 1500),
                AttachmentVideoPlayer(attachment: videoAttachment),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('clip.mp4', skipOffstage: false),
      findsOneWidget,
    );
    expect(players, 0, reason: 'built in the cache extent, never seen');

    controller.jumpTo(1400);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(players, 1);
  });

  group('while full screen is open', () {
    late FakePlayer player;
    late ScriptedSource source;
    late Completer<void> fullscreen;
    late VoidCallback openFullscreen;

    setUp(() {
      player = FakePlayer();
      source = ScriptedSource([media]);
    });

    Future<void> pumpOpened(WidgetTester tester) async {
      fullscreen = Completer<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiProvider.overrideWithValue(
              api.SlimmApi(baseUrl: Uri.parse('http://localhost:1')),
            ),
            attachmentVideoSourceProvider.overrideWithValue(() => source),
            attachmentPlayerProvider.overrideWithValue(() => player),
            attachmentVideoControllerProvider.overrideWithValue(
              (_) => FakeVideoController(),
            ),
            attachmentVideoSurfaceProvider.overrideWithValue((
              player,
              controller,
              onToggleFullscreen,
              onSave,
              saving,
            ) {
              openFullscreen = onToggleFullscreen;
              return const SizedBox(key: Key('ready-surface'));
            }),
            attachmentFullscreenOpenerProvider.overrideWithValue(
              (
                context, {
                required player,
                required controller,
                required filename,
              }) => fullscreen.future,
            ),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(
              body: AttachmentVideoPlayer(attachment: videoAttachment),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      openFullscreen();
      await tester.pump();
    }

    testWidgets('the row unmounting leaves the player playing', (tester) async {
      await pumpOpened(tester);

      await tester.pumpWidget(const SizedBox());

      expect(player.disposed, isFalse);
      expect(source.disposed, isFalse);
      expect(player.errors.hasListener, isTrue);
    });

    testWidgets('closing it afterwards disposes the player and the source', (
      tester,
    ) async {
      await pumpOpened(tester);
      await tester.pumpWidget(const SizedBox());

      fullscreen.complete();
      await tester.idle();
      await tester.pump();

      expect(player.disposed, isTrue);
      expect(source.disposed, isTrue);
    });

    testWidgets('closing it while the row stays keeps the player', (
      tester,
    ) async {
      await pumpOpened(tester);

      fullscreen.complete();
      await tester.idle();
      await tester.pump();

      expect(player.disposed, isFalse);
      expect(find.byKey(const Key('ready-surface')), findsOneWidget);
    });
  });
}
