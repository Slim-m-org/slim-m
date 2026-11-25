// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One native player for every account: who owns the view, that a lookalike
/// origin never loads in the phone webview, and that a view which mounts
/// late or a command that fails does not strand the player.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/video/providers/desktop_video.dart';
import 'package:slimm_app/src/features/video/providers/desktop_video_player.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/video/providers/native_video_host.dart';
import 'package:slimm_app/src/features/video/providers/youtube_bridge_player.dart';
import 'package:slimm_app/src/features/video/providers/youtube_webview_player.dart';

class _ThrowingPlayer extends YoutubeBridgePlayer {
  @override
  Future<void> runScript(String script) async =>
      throw PlatformException(code: 'gone');

  @override
  Future<void> disposeHost() async {}
}

const _url = 'https://youtu.be/dQw4w9WgXcQ';
const _preview = LinkPreview(
  url: _url,
  title: 'A talk',
  videoProvider: LinkPreviewVideoProvider.youtube,
  videoId: 'dQw4w9WgXcQ',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(NativeVideoHost.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  var nextTexture = 0;

  setUp(() {
    calls.clear();
    nextTexture = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'create' ? ++nextTexture : null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> runnerSays(String message) => messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall('message', message)),
    (_) {},
  );

  group('the webview host navigation check', () {
    test('only the exact host origin and a blank page load', () {
      expect(isYoutubeHostNavigation('https://top.npcserver.slimm/'), isTrue);
      expect(
        isYoutubeHostNavigation(
          'https://top.npcserver.slimm/youtube_host.html',
        ),
        isTrue,
      );
      expect(isYoutubeHostNavigation('about:blank'), isTrue);
    });

    test('a lookalike origin or a data page does not', () {
      expect(
        isYoutubeHostNavigation('https://top.npcserver.slimm.evil.example/'),
        isFalse,
      );
      expect(
        isYoutubeHostNavigation('https://top.npcserver.slimm@evil.example/'),
        isFalse,
      );
      expect(isYoutubeHostNavigation('http://top.npcserver.slimm/'), isFalse);
      expect(
        isYoutubeHostNavigation('https://top.npcserver.slimm:8443/'),
        isFalse,
      );
      expect(isYoutubeHostNavigation('data:text/html,hi'), isFalse);
      expect(isYoutubeHostNavigation('about:srcdoc'), isFalse);
      expect(isYoutubeHostNavigation('not a url'), isFalse);
    });
  });

  group('two accounts on the one native view', () {
    test('the second account takes the view and the first hears it', () async {
      final host = NativeVideoHost();
      final first = TextureVideoPlayer(host);
      final second = TextureVideoPlayer(host);
      var firstDisplaced = 0;
      first.displaced.listen((_) => firstDisplaced++);
      final firstEvents = <VideoPlayerEvent>[];
      first.events.listen(firstEvents.add);
      final secondEvents = <VideoPlayerEvent>[];
      second.events.listen(secondEvents.add);

      await first.resize(const Size(100, 50), 1);
      await second.resize(const Size(100, 50), 1);
      await runnerSays('{"event":"ready"}');
      await Future<void>.delayed(Duration.zero);

      expect(firstDisplaced, 1);
      expect(first.texture.value, isNull);
      expect(second.texture.value, 2);
      expect(secondEvents.single, isA<VideoReady>());
      expect(firstEvents, isEmpty);
    });

    test('a displaced player neither drives nor destroys the view', () async {
      final host = NativeVideoHost();
      final first = TextureVideoPlayer(host);
      final second = TextureVideoPlayer(host);
      await first.resize(const Size(100, 50), 1);
      await second.resize(const Size(100, 50), 1);
      calls.clear();

      await first.resize(const Size(200, 100), 1);
      await first.pointer(VideoPointerKind.down, Offset.zero);
      await first.dispose();
      expect(calls, isEmpty);

      await second.dispose();
      expect(calls, ['destroy']);
    });

    test('the controller closes the video its player lost', () async {
      final host = NativeVideoHost();
      final container = ProviderContainer(
        overrides: [
          desktopVideoPlayerFactoryProvider.overrideWithValue(
            () => TextureVideoPlayer(host),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(desktopVideoProvider.notifier)
          .playIn(Object(), _url, _preview);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(desktopVideoProvider), isNotNull);

      await TextureVideoPlayer(host).resize(const Size(100, 50), 1);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(desktopVideoProvider), isNull);
    });
  });

  group('a player whose view is slow to mount', () {
    test('a load builds the view with nothing laid out', () async {
      final player = TextureVideoPlayer(NativeVideoHost());
      unawaited(player.load('dQw4w9WgXcQ'));
      await Future<void>.delayed(Duration.zero);

      expect(calls, ['create']);
      expect(player.texture.value, 1);
    });

    test('a late first layout still plays', () {
      fakeAsync((async) {
        final player = TextureVideoPlayer(NativeVideoHost());
        final events = <VideoPlayerEvent>[];
        player.events.listen(events.add);
        unawaited(player.load('dQw4w9WgXcQ'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 20));
        unawaited(runnerSays('{"event":"host"}'));
        async.flushMicrotasks();
        unawaited(player.resize(const Size(100, 50), 1));
        async.flushMicrotasks();

        expect(events, isEmpty);
        expect(calls, ['create', 'run', 'resize']);
      });
    });
  });

  test('a command the platform refuses reports a failed player', () async {
    final player = _ThrowingPlayer()..handleMessage('{"event":"host"}');
    final events = <VideoPlayerEvent>[];
    player.events.listen(events.add);

    await player.play();
    await Future<void>.delayed(Duration.zero);

    expect((events.single as VideoFailed).code, -1);
  });
}
