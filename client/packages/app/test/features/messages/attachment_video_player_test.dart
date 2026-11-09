// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AttachmentVideoPlayer] constructs a real `media_kit` [Player] the moment
/// it is first seen (see `_ensurePlayback`), so every test here
/// needs [MediaKit.ensureInitialized] and a real libmpv on the machine
/// running it - `client-ci.yml`'s test job installs the runtime `libmpv2` for exactly
/// this. What is tested never needs that player to actually open anything:
/// a caller with no access token fails inside `AttachmentVideoSource.open`
/// itself, before `Player.open` is ever reached, so this is deterministic
/// rather than dependent on a real network fetch settling in time.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_video_player.dart';
import 'package:slimm_design_system/design_system.dart';

import 'attachment_video_fakes.dart';

Future<void> _pumpFaked(
  WidgetTester tester,
  ScriptedSource source,
  FakePlayer player,
) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(
          api.SlimmApi(baseUrl: Uri.parse('http://localhost:1')),
        ),
        attachmentVideoSourceProvider.overrideWithValue(() => source),
        attachmentPlayerProvider.overrideWithValue(() => player),
        attachmentVideoControllerProvider.overrideWithValue((_) {
          player.lifecycle.add('controller');
          return FakeVideoController();
        }),
        attachmentVideoSurfaceProvider.overrideWithValue(
          (player, controller, onToggleFullscreen, onSave, saving) =>
              const SizedBox(key: Key('ready-surface')),
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
}

Future<void> _pumpPlayer(WidgetTester tester, ScriptedSource source) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(
          api.SlimmApi(baseUrl: Uri.parse('http://localhost:1')),
        ),
        attachmentVideoSourceProvider.overrideWithValue(() => source),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: AttachmentVideoPlayer(attachment: videoAttachment),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(MediaKit.ensureInitialized);

  testWidgets(
    'a failed load offers Retry, and retrying opens the source again',
    (tester) async {
      final source = ScriptedSource([Exception('boom')]);
      await _pumpPlayer(tester, source);
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Could not load ${videoAttachment.filename}.'),
        findsOneWidget,
      );
      final retry = find.text('Retry');
      expect(retry, findsOneWidget);

      await tester.tap(retry);
      await tester.pump();

      expect(source.opens, 2);
    },
  );

  testWidgets('disposing the player disposes its source', (tester) async {
    final source = ScriptedSource([Exception('boom')]);
    await _pumpPlayer(tester, source);
    await tester.pump();
    expect(source.disposed, isFalse);

    await tester.pumpWidget(const SizedBox());

    expect(source.disposed, isTrue);
  });

  testWidgets('signed out surfaces the load failure through AppErrorState', (
    tester,
  ) async {
    final signedOut = api.SlimmApi(baseUrl: Uri.parse('http://localhost:1'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(signedOut)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: AttachmentVideoPlayer(attachment: videoAttachment),
          ),
        ),
      ),
    );
    await tester.pump();

    // Still loading here (the failure lands on the next pump).
    expect(
      find.byWidgetPredicate(
        (w) => w is CircularProgressIndicator && w.value == null,
      ),
      findsNothing,
    );
    expect(find.text('Loading video…'), findsOneWidget);

    await tester.pump();

    expect(
      find.text(
        'Could not load ${videoAttachment.filename}: you are signed out. '
        'Sign in and try again.',
      ),
      findsOneWidget,
    );
    expect(find.byType(Video), findsNothing);
  });

  group('with a fake player', () {
    final media = Media('http://localhost:1/clip.mp4');

    testWidgets('a loaded source is opened on the player, paused', (
      tester,
    ) async {
      final player = FakePlayer();
      await _pumpFaked(tester, ScriptedSource([media]), player);
      await tester.pump();
      await tester.pump();

      expect(player.opened.single, media);
      expect(player.autoplay.single, isFalse);
      expect(find.byKey(const Key('ready-surface')), findsOneWidget);
      expect(find.text('Loading video…'), findsNothing);
    });

    testWidgets('the render context exists before the file opens', (
      tester,
    ) async {
      final player = FakePlayer();
      await _pumpFaked(tester, ScriptedSource([media]), player);
      await tester.pump();
      await tester.pump();

      expect(player.lifecycle, ['controller', 'open']);
    });

    testWidgets('a failure while playing is shown as an error', (tester) async {
      final player = FakePlayer();
      await _pumpFaked(tester, ScriptedSource([media]), player);
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Could not play ${videoAttachment.filename}.'),
        findsNothing,
      );

      player.errors.add('decode failed');
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Could not play ${videoAttachment.filename}.'),
        findsOneWidget,
      );
    });

    testWidgets('a failed load does not open the player', (tester) async {
      final player = FakePlayer();
      await _pumpFaked(tester, ScriptedSource([Exception('boom')]), player);
      await tester.pump();
      await tester.pump();

      expect(player.opened, isEmpty);
      expect(find.byKey(const Key('ready-surface')), findsNothing);
      expect(
        find.text('Could not load ${videoAttachment.filename}.'),
        findsOneWidget,
      );
    });

    testWidgets('a retry after a failed load opens the player once it works', (
      tester,
    ) async {
      final player = FakePlayer();
      final source = ScriptedSource([Exception('boom'), media]);
      await _pumpFaked(tester, source, player);
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();

      expect(source.opens, 2);
      expect(player.opened.single, media);
      expect(
        find.text('Could not load ${videoAttachment.filename}.'),
        findsNothing,
      );
      expect(find.byKey(const Key('ready-surface')), findsOneWidget);
    });

    testWidgets('a row outside the viewport opens nothing until scrolled in', (
      tester,
    ) async {
      final player = FakePlayer();
      final source = ScriptedSource([media]);
      final controller = ScrollController();
      addTearDown(controller.dispose);
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
      expect(source.opens, 0, reason: 'built in the cache extent, never seen');
      expect(player.opened, isEmpty);

      controller.jumpTo(1400);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(source.opens, 1);
      expect(player.opened.single, media);
    });

    testWidgets('an unfocused window opens nothing, and losing focus pauses', (
      tester,
    ) async {
      final binding = TestWidgetsFlutterBinding.instance;
      addTearDown(
        () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final player = FakePlayer();
      final source = ScriptedSource([media]);
      await _pumpFaked(tester, source, player);
      await tester.pump();
      await tester.pump();
      expect(source.opens, 0);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(source.opens, 1);
      expect(player.pauses, 0);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(player.pauses, 1, reason: 'nobody is watching it play');
    });

    testWidgets('disposing disposes the player and the source', (tester) async {
      final player = FakePlayer();
      final source = ScriptedSource([media]);
      await _pumpFaked(tester, source, player);
      await tester.pump();
      await tester.pump();

      await tester.pumpWidget(const SizedBox());

      expect(player.disposed, isTrue);
      expect(source.disposed, isTrue);
      expect(player.errors.hasListener, isFalse);
    });
  });
}
