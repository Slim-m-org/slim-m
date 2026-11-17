// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The soundboard player hands a clip's bytes to audioplayers, plays it, and
/// releases the player once the clip ends.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/sound_clip_player.dart';

const _channels = ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global'];
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

/// Answers the audioplayers channels the way the Linux plugin does for a clip that decodes.
class _FakePlugin {
  _FakePlugin(this._messenger);

  final TestDefaultBinaryMessenger _messenger;
  final calls = <String>[];
  final _sinks = <String, MockStreamHandlerEventSink>{};
  final disposed = Completer<void>();

  void install() {
    for (final name in _channels) {
      _messenger.setMockMethodCallHandler(MethodChannel(name), _handle);
    }
  }

  void uninstall() {
    for (final name in _channels) {
      _messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call.method);
    final id = (call.arguments as Map?)?['playerId'] as String?;
    switch (call.method) {
      case 'create':
        _messenger.setMockStreamHandler(
          EventChannel('xyz.luan/audioplayers/events/$id'),
          MockStreamHandler.inline(onListen: (_, sink) => _sinks[id!] = sink),
        );
      case 'setSourceBytes' || 'setSourceUrl':
        _sinks[id]?.success({'event': 'audio.onPrepared', 'value': true});
      case 'resume':
        _sinks[id]?.success({'event': 'audio.onComplete'});
      case 'dispose':
        if (!disposed.isCompleted) disposed.complete();
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlugin plugin;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    plugin = _FakePlugin(messenger)..install();
    final temp = Directory.systemTemp.createTempSync('sound-clip-test');
    messenger.setMockMethodCallHandler(_pathProvider, (_) async => temp.path);
    addTearDown(() {
      plugin.uninstall();
      messenger.setMockMethodCallHandler(_pathProvider, null);
      temp.deleteSync(recursive: true);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  for (final (platform, source) in [
    (TargetPlatform.linux, 'setSourceUrl'),
    (TargetPlatform.windows, 'setSourceBytes'),
  ]) {
    test('on ${platform.name} a clip plays and frees its player', () async {
      debugDefaultTargetPlatformOverride = platform;

      await AudioPlayersSoundClipPlayer().play(
        Uint8List.fromList(List.filled(64, 1)),
        mimeType: 'audio/mpeg',
        volume: 1,
      );
      await plugin.disposed.future.timeout(const Duration(seconds: 2));

      expect(plugin.calls, containsAllInOrder([source, 'resume', 'dispose']));
    });
  }
}
