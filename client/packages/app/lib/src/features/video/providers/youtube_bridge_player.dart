// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An [EmbeddedVideoPlayer] over `youtube_host_page.dart`'s page: commands go
/// in as script, events come back as JSON. A host supplies only the two ends.
library;

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show protected;

import 'embedded_video_player.dart';

abstract class YoutubeBridgePlayer implements EmbeddedVideoPlayer {
  final _events = StreamController<VideoPlayerEvent>.broadcast();
  final _pageLoaded = Completer<void>();
  Duration _position = Duration.zero;
  DateTime? _playingSince;
  bool _disposed = false;

  /// Runs [script] in the host page.
  Future<void> runScript(String script);

  /// A command sent before the page defined `window.slimm` would be lost.
  Future<void> _command(String script) async {
    try {
      await _pageLoaded.future.timeout(_pageLoadLimit);
    } on TimeoutException {
      reportHostFailure();
      return;
    }
    if (!_disposed) await runScript(script);
  }

  /// The host or its page never came up, so the panel shows why instead of
  /// an empty box.
  @protected
  void reportHostFailure() {
    if (!_disposed) _events.add(const VideoFailed(-1));
  }

  /// Tears down whatever hosts the page.
  Future<void> disposeHost();

  @override
  Stream<VideoPlayerEvent> get events => _events.stream;

  @override
  Future<void> load(String videoId, {Duration start = Duration.zero}) {
    _position = start;
    _playingSince = null;
    return _command(
      'window.slimm.load(${jsonEncode(videoId)}, ${_seconds(start)})',
    );
  }

  @override
  Future<void> play() => _command('window.slimm.play()');

  @override
  Future<void> pause() => _command('window.slimm.pause()');

  Future<void> exitFullscreen() => _command('window.slimm.exitFullscreen()');

  @override
  Future<void> seekTo(Duration position) {
    _position = position;
    if (_playingSince != null) _playingSince = clock.now();
    return _command('window.slimm.seek(${_seconds(position)})');
  }

  /// Advances the last report by the time spent playing since, so a caller
  /// polling between the page's half-second reports does not see it stall.
  @override
  Future<Duration> position() async {
    final since = _playingSince;
    if (since == null) return _position;
    return _position + clock.now().difference(since);
  }

  /// One message from the page; anything unreadable is ignored.
  void handleMessage(String text) {
    if (_disposed) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    if (decoded['event'] == 'host' && !_pageLoaded.isCompleted) {
      _pageLoaded.complete();
    }
    final event = switch (decoded['event']) {
      'ready' => const VideoReady(),
      'state' => _stateEvent(decoded['s']),
      'error' => VideoFailed(switch (decoded['code']) {
        final num code => code.toInt(),
        _ => -1,
      }),
      'time' => _time(decoded['t']),
      'fullscreen' => VideoFullscreenChanged(on: decoded['on'] == true),
      _ => null,
    };
    if (event != null) _events.add(event);
  }

  VideoPlayerEvent? _stateEvent(Object? state) {
    final playing = state == 1;
    _playingSince = playing ? clock.now() : null;
    return switch (state) {
      0 => const VideoEnded(),
      1 => const VideoPlaying(),
      2 => const VideoPaused(),
      3 => const VideoBuffering(),
      _ => null,
    };
  }

  VideoPlayerEvent? _time(Object? seconds) {
    if (seconds is! num) return null;
    _position = Duration(milliseconds: (seconds * 1000).round());
    if (_playingSince != null) _playingSince = clock.now();
    return null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _events.close();
    await disposeHost();
  }
}

const _pageLoadLimit = Duration(seconds: 30);

String _seconds(Duration d) => (d.inMilliseconds / 1000).toString();
