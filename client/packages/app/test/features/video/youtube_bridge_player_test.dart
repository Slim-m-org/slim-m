// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared player over the YouTube host page: what script each command
/// becomes, that nothing is sent before the page can take it, and how the
/// page's messages read as events.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/video/providers/native_video_host.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/video/providers/youtube_bridge_player.dart';

class _ScriptPlayer extends YoutubeBridgePlayer {
  final scripts = <String>[];
  bool hostDisposed = false;

  @override
  Future<void> runScript(String script) async => scripts.add(script);

  @override
  Future<void> disposeHost() async => hostDisposed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the desktop probe', () {
    const channel = MethodChannel(NativeVideoHost.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('a runner without the channel reports no player', () async {
      expect(await NativeVideoHost().probe(), isFalse);
    });

    test('a runner missing WebKit or WebView2 reports no player', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      expect(await NativeVideoHost().probe(), isFalse);
    });

    test('a runner that can host it says so', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => true);
      expect(await NativeVideoHost().probe(), isTrue);
    });

    test('a view that cannot be built reports a failed player', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'create' ? false : null,
      );
      final player = NativeDockedPlayer(NativeVideoHost());
      final events = <VideoPlayerEvent>[];
      player.events.listen(events.add);

      await player.setBounds((x: 0, y: 0, width: 360, height: 202.5));
      await Future<void>.delayed(Duration.zero);

      expect(events.single, isA<VideoFailed>());
      expect((events.single as VideoFailed).code, -1);
    });
  });

  test('commands wait for the page, then run in order', () async {
    final player = _ScriptPlayer();
    final load = player.load('dQw4w9WgXcQ', start: const Duration(seconds: 90));
    final play = player.play();
    await Future<void>.delayed(Duration.zero);
    expect(player.scripts, isEmpty);

    player.handleMessage('{"event":"host"}');
    await Future.wait([load, play]);

    expect(player.scripts, [
      'window.slimm.load("dQw4w9WgXcQ", 90.0)',
      'window.slimm.play()',
    ]);
  });

  test('a page that never says it is up reports a failed player', () {
    fakeAsync((async) {
      final player = _ScriptPlayer();
      final events = <VideoPlayerEvent>[];
      player.events.listen(events.add);
      unawaited(player.load('dQw4w9WgXcQ'));

      async.elapse(const Duration(seconds: 29));
      expect(events, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(events.single, isA<VideoFailed>());
      expect(player.scripts, isEmpty);
    });
  });

  test('pause, seek and fullscreen exit become their page calls', () async {
    final player = _ScriptPlayer()..handleMessage('{"event":"host"}');
    await player.pause();
    await player.seekTo(const Duration(milliseconds: 1500));
    await player.exitFullscreen();
    expect(player.scripts, [
      'window.slimm.pause()',
      'window.slimm.seek(1.5)',
      'window.slimm.exitFullscreen()',
    ]);
  });

  test('an id is quoted as a string, never spliced into script', () async {
    final player = _ScriptPlayer()..handleMessage('{"event":"host"}');
    await player.load('a"); alert(1); ("');
    expect(player.scripts.single, contains(r'"a\"); alert(1); (\""'));
  });

  test("the page's messages read as player events", () async {
    final player = _ScriptPlayer();
    final events = <VideoPlayerEvent>[];
    player.events.listen(events.add);
    for (final message in [
      '{"event":"ready"}',
      '{"event":"state","s":3}',
      '{"event":"state","s":1}',
      '{"event":"state","s":2}',
      '{"event":"state","s":0}',
      '{"event":"error","code":150}',
      '{"event":"fullscreen","on":true}',
      '{"event":"state","s":5}',
      'not json',
      '[1,2]',
    ]) {
      player.handleMessage(message);
    }
    await Future<void>.delayed(Duration.zero);
    expect(events.map((e) => e.runtimeType), [
      VideoReady,
      VideoBuffering,
      VideoPlaying,
      VideoPaused,
      VideoEnded,
      VideoFailed,
      VideoFullscreenChanged,
    ]);
    expect((events[5] as VideoFailed).embeddingRefused, isTrue);
    expect((events[6] as VideoFullscreenChanged).on, isTrue);
    expect(const VideoFailed(100).embeddingRefused, isFalse);
  });

  test('a malformed error from a frame reports an unknown error', () async {
    final player = _ScriptPlayer();
    final events = <VideoPlayerEvent>[];
    player.events.listen(events.add);
    player.handleMessage('{"event":"error","code":"150"}');
    await Future<void>.delayed(Duration.zero);
    expect((events.single as VideoFailed).code, -1);
  });

  test('position follows the clock between reports while playing', () {
    fakeAsync((async) {
      withClock(async.getClock(DateTime(2026)), () {
        final player = _ScriptPlayer();
        Duration? read;
        unawaited(player.position().then((p) => read = p));
        async.flushMicrotasks();
        expect(read, Duration.zero);

        player.handleMessage('{"event":"time","t":12.5,"d":200}');
        player.handleMessage('{"event":"state","s":1}');
        async.elapse(const Duration(seconds: 2));
        unawaited(player.position().then((p) => read = p));
        async.flushMicrotasks();
        expect(read, const Duration(milliseconds: 14500));

        player.handleMessage('{"event":"state","s":2}');
        async.elapse(const Duration(seconds: 5));
        unawaited(player.position().then((p) => read = p));
        async.flushMicrotasks();
        expect(read, const Duration(milliseconds: 12500));
      });
    });
  });

  test('a load starts the reported position at its start', () async {
    final player = _ScriptPlayer()..handleMessage('{"event":"host"}');
    await player.load('dQw4w9WgXcQ', start: const Duration(seconds: 42));
    expect(await player.position(), const Duration(seconds: 42));
  });

  test('dispose tears the host down and stops events', () async {
    final player = _ScriptPlayer();
    final done = Completer<void>();
    player.events.listen(null, onDone: done.complete);
    await player.dispose();
    await done.future;
    expect(player.hostDisposed, isTrue);
    player.handleMessage('{"event":"ready"}');
  });
}
