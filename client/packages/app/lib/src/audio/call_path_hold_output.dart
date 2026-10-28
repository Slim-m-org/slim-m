// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hold music on iPhone, played by the app's own audio engine alongside the
/// call instead of by a plugin that resets the call's audio session.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'hold_music_player.dart';
import 'lounge_tracks.dart';

const holdMusicChannelName = 'top.npcserver.slimm/hold_music';

/// How often the badge's timeline asks the engine where the loop is.
const _positionPoll = Duration(milliseconds: 500);

class CallPathHoldOutput implements HoldLoopOutput {
  CallPathHoldOutput({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(holdMusicChannelName);

  final MethodChannel _channel;
  final _playback = ValueNotifier(HoldPlayback.idle);
  Timer? _poll;
  double _volume = defaultHoldMusicVolume;

  @override
  ValueListenable<HoldPlayback> get playback => _playback;

  @override
  Future<void> play(String asset) async {
    _stopPolling();
    final seconds = await _invoke<double>('play', {
      'path': await _pathOf(asset),
      'volume': _volume,
    });
    _playback.value = HoldPlayback(
      duration: seconds == null
          ? null
          : Duration(milliseconds: (seconds * 1000).round()),
    );
    _startPolling();
  }

  /// The bundle path of a Flutter asset; the native side cannot resolve a Dart key.
  Future<String> _pathOf(String asset) async {
    final key = await _channel.invokeMethod<String>('assetPath', {
      'asset': 'assets/$asset',
    });
    return key ?? '';
  }

  void _startPolling() {
    _poll = Timer.periodic(_positionPoll, (_) async {
      final seconds = await _invoke<double>('position');
      if (seconds == null || _poll == null) return;
      _playback.value = _playback.value.copyWith(
        position: Duration(milliseconds: (seconds * 1000).round()),
      );
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Hold music $method failed',
        error,
        stack,
      );
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> stop() async {
    _stopPolling();
    _playback.value = HoldPlayback.idle;
    await _invoke<void>('stop');
  }

  @override
  Future<void> pause() async {
    _stopPolling();
    await _invoke<void>('pause');
  }

  @override
  Future<void> resume() async {
    await _invoke<void>('resume');
    if (_poll == null) _startPolling();
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _invoke<void>('setVolume', {'volume': volume});
  }

  @override
  Future<void> seek(Duration position) async {
    await _invoke<void>('seek', {'seconds': position.inMilliseconds / 1000});
    _playback.value = _playback.value.copyWith(position: position);
  }

  @override
  Future<void> dispose() => stop();
}
