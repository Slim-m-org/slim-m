// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AttachmentVideoPlayer] constructs a real `media_kit` [Player] the moment
/// it mounts (see the widget's own field initializer), so every test here
/// needs [MediaKit.ensureInitialized] and a real libmpv on the machine
/// running it - `client-ci.yml`'s test job installs the runtime `libmpv2` for exactly
/// this. What is tested never needs that player to actually open anything:
/// a caller with no access token fails inside `AttachmentVideoSource.open`
/// itself, before `Player.open` is ever reached, so this is deterministic
/// rather than dependent on a real network fetch settling in time.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_video_player.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_video_source.dart';
import 'package:slimm_design_system/design_system.dart';

const _video = api.Attachment(
  id: 'v1',
  filename: 'clip.mp4',
  contentType: 'video/mp4',
  size: 12000000,
);

/// Answers [open] from a script instead of the network, cycling its outcomes.
///
/// Only failing outcomes are scripted: `Player.open` waits on the video
/// controller's GL texture, which a headless test never gets, so a load that
/// succeeds never resolves here and the ready path stays out of reach.
class _ScriptedSource implements AttachmentVideoSource {
  _ScriptedSource(this._outcomes);

  final List<Object> _outcomes;
  int opens = 0;
  bool disposed = false;

  @override
  Future<Media> open({
    required api.SlimmApi apiClient,
    required api.Attachment attachment,
    required void Function(double? progress) onProgress,
  }) async {
    final next = _outcomes[opens < _outcomes.length ? opens : 0];
    opens += 1;
    if (next is Media) return next;
    throw next;
  }

  @override
  bool isStale(api.SlimmApi apiClient) => false;

  @override
  void dispose() => disposed = true;
}

/// A [Player] that records its lifecycle and lets a test fire stream events.
///
/// Only what the widget and its token reopener touch is real; anything else
/// throws, so a new dependency on the player fails loudly here.
class _FakePlayer implements Player {
  final errors = StreamController<String>.broadcast();
  final playing = StreamController<bool>.broadcast();
  final buffering = StreamController<bool>.broadcast();
  final lifecycle = <String>[];
  final opened = <Playable>[];
  final autoplay = <bool>[];
  bool disposed = false;
  int pauses = 0;

  @override
  Future<void> pause() async => pauses += 1;

  @override
  late final PlayerStream stream = _FakeStream(this);

  @override
  PlayerState get state => const PlayerState();

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    lifecycle.add('open');
    opened.add(playable);
    autoplay.add(play);
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {
    disposed = true;
    await errors.close();
    await playing.close();
    await buffering.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Stands in for the render context a headless test cannot create.
class _FakeVideoController implements VideoController {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeStream implements PlayerStream {
  _FakeStream(this._player);

  final _FakePlayer _player;

  @override
  Stream<String> get error => _player.errors.stream;

  @override
  Stream<bool> get playing => _player.playing.stream;

  @override
  Stream<bool> get buffering => _player.buffering.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<void> _pumpFaked(
  WidgetTester tester,
  _ScriptedSource source,
  _FakePlayer player,
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
          return _FakeVideoController();
        }),
        attachmentVideoSurfaceProvider.overrideWithValue(
          (player, controller, onToggleFullscreen) =>
              const SizedBox(key: Key('ready-surface')),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: AttachmentVideoPlayer(attachment: _video)),
      ),
    ),
  );
}

Future<void> _pumpPlayer(WidgetTester tester, _ScriptedSource source) {
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
        home: const Scaffold(body: AttachmentVideoPlayer(attachment: _video)),
      ),
    ),
  );
}

void main() {
  setUpAll(MediaKit.ensureInitialized);

  testWidgets(
    'a failed load offers Retry, and retrying opens the source again',
    (tester) async {
      final source = _ScriptedSource([Exception('boom')]);
      await _pumpPlayer(tester, source);
      await tester.pump();
      await tester.pump();

      expect(find.text('Could not load ${_video.filename}.'), findsOneWidget);
      final retry = find.text('Retry');
      expect(retry, findsOneWidget);

      await tester.tap(retry);
      await tester.pump();

      expect(source.opens, 2);
    },
  );

  testWidgets('disposing the player disposes its source', (tester) async {
    final source = _ScriptedSource([Exception('boom')]);
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
          home: const Scaffold(body: AttachmentVideoPlayer(attachment: _video)),
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
        'Could not load ${_video.filename}: you are signed out. '
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
      final player = _FakePlayer();
      await _pumpFaked(tester, _ScriptedSource([media]), player);
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
      final player = _FakePlayer();
      await _pumpFaked(tester, _ScriptedSource([media]), player);
      await tester.pump();
      await tester.pump();

      expect(player.lifecycle, ['controller', 'open']);
    });

    testWidgets('a failure while playing is shown as an error', (tester) async {
      final player = _FakePlayer();
      await _pumpFaked(tester, _ScriptedSource([media]), player);
      await tester.pump();
      await tester.pump();
      expect(find.text('Could not play ${_video.filename}.'), findsNothing);

      player.errors.add('decode failed');
      await tester.pump();
      await tester.pump();

      expect(find.text('Could not play ${_video.filename}.'), findsOneWidget);
    });

    testWidgets('a failed load does not open the player', (tester) async {
      final player = _FakePlayer();
      await _pumpFaked(tester, _ScriptedSource([Exception('boom')]), player);
      await tester.pump();
      await tester.pump();

      expect(player.opened, isEmpty);
      expect(find.byKey(const Key('ready-surface')), findsNothing);
      expect(find.text('Could not load ${_video.filename}.'), findsOneWidget);
    });

    testWidgets('a retry after a failed load opens the player once it works', (
      tester,
    ) async {
      final player = _FakePlayer();
      final source = _ScriptedSource([Exception('boom'), media]);
      await _pumpFaked(tester, source, player);
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();

      expect(source.opens, 2);
      expect(player.opened.single, media);
      expect(find.text('Could not load ${_video.filename}.'), findsNothing);
      expect(find.byKey(const Key('ready-surface')), findsOneWidget);
    });

    testWidgets('a row outside the viewport opens nothing until scrolled in', (
      tester,
    ) async {
      final player = _FakePlayer();
      final source = _ScriptedSource([media]);
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
              (_) => _FakeVideoController(),
            ),
            attachmentVideoSurfaceProvider.overrideWithValue(
              (player, controller, onToggleFullscreen) =>
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
                  AttachmentVideoPlayer(attachment: _video),
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
      final player = _FakePlayer();
      final source = _ScriptedSource([media]);
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
      final player = _FakePlayer();
      final source = _ScriptedSource([media]);
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
