// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// YouTube's embed on youtube-nocookie.com in an iframe, driven through the
/// JSON messages the embed itself accepts (`listening`, then `command`s),
/// since the page's content security policy admits YouTube as a frame and
/// never as a script, so the IFrame API's own loader cannot run here.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'embedded_video_player.dart';

const _embedOrigin = 'https://www.youtube-nocookie.com';

/// How long the embed has to answer the handshake before the stage says it failed.
const _handshakeLimit = Duration(seconds: 20);

int _nextId = 0;

class IframeYoutubePlayer implements EmbeddedVideoPlayer {
  IframeYoutubePlayer() : _id = ++_nextId {
    _frame
      ..allow = 'autoplay; encrypted-media; picture-in-picture; fullscreen'
      ..allowFullscreen = true;
    _frame.style
      ..setProperty('border', 'none')
      ..setProperty('width', '100%')
      ..setProperty('height', '100%');
    final viewType = 'slimm-watch-youtube-$_id';
    ui_web.platformViewRegistry.registerViewFactory(
      viewType,
      (int _) => _frame,
    );
    view = HtmlElementView(viewType: viewType);
    _onMessage = _receive.toJS;
    web.window.addEventListener('message', _onMessage);
  }

  final int _id;
  final web.HTMLIFrameElement _frame = web.HTMLIFrameElement();
  late final Widget view;
  late final JSFunction _onMessage;
  final _events = StreamController<VideoPlayerEvent>.broadcast();
  final _queued = <Map<String, Object?>>[];
  Timer? _handshake;
  DateTime? _handshakeStarted;
  bool _ready = false;
  bool _disposed = false;
  Duration _position = Duration.zero;
  DateTime? _playingSince;
  int? _state;

  @override
  Stream<VideoPlayerEvent> get events => _events.stream;

  @override
  Future<void> load(String videoId, {Duration start = Duration.zero}) async {
    _position = start;
    _playingSince = null;
    if (_frame.src.isEmpty) {
      _frame.src = _embedUrl(videoId, start).toString();
      _startHandshake();
      return;
    }
    _command('loadVideoById', [
      {'videoId': videoId, 'startSeconds': start.inMilliseconds / 1000},
    ]);
  }

  @override
  Future<void> play() async => _command('playVideo');

  @override
  Future<void> pause() async => _command('pauseVideo');

  @override
  Future<void> seekTo(Duration position) async {
    _position = position;
    if (_playingSince != null) _playingSince = clock.now();
    _command('seekTo', [position.inMilliseconds / 1000, true]);
  }

  @override
  Future<Duration> position() async {
    final since = _playingSince;
    return since == null
        ? _position
        : _position + clock.now().difference(since);
  }

  Uri _embedUrl(String videoId, Duration start) {
    final origin = web.window.location.origin;
    return Uri.parse(
      '$_embedOrigin/embed/${Uri.encodeComponent(videoId)}',
    ).replace(
      queryParameters: {
        'enablejsapi': '1',
        'autoplay': '1',
        'playsinline': '1',
        'rel': '0',
        'start': '${start.inSeconds}',
        'origin': origin,
        'widget_referrer': origin,
      },
    );
  }

  /// The embed only talks once told someone is listening, so this repeats until it answers.
  void _startHandshake() {
    _handshakeStarted = clock.now();
    _handshake = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (clock.now().difference(_handshakeStarted!) > _handshakeLimit) {
        _handshake?.cancel();
        if (!_disposed) _events.add(const VideoFailed(-1));
        return;
      }
      _post({'event': 'listening'});
    });
  }

  void _command(String func, [List<Object?> args = const []]) {
    final message = {'event': 'command', 'func': func, 'args': args};
    if (_ready) {
      _post(message);
    } else {
      _queued.add(message);
    }
  }

  void _post(Map<String, Object?> message) {
    if (_disposed) return;
    final text = jsonEncode({...message, 'id': _id, 'channel': 'widget'});
    _frame.contentWindow?.postMessage(text.toJS, _embedOrigin.toJS);
  }

  void _receive(web.MessageEvent event) {
    if (_disposed || event.origin != _embedOrigin) return;
    final data = event.data;
    if (data == null || !data.isA<JSString>()) return;
    final Object? decoded;
    try {
      decoded = jsonDecode((data as JSString).toDart);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final ours =
        decoded['id'] == _id ||
        event.source.strictEquals(_frame.contentWindow).toDart;
    if (!ours) return;
    _handshake?.cancel();
    switch (decoded['event']) {
      case 'onReady':
        _onReady();
      case 'onStateChange':
        _onState(decoded['info']);
      case 'onError':
        final code = decoded['info'];
        _events.add(VideoFailed(code is num ? code.toInt() : -1));
      case 'infoDelivery' || 'initialDelivery':
        final info = decoded['info'];
        if (info is Map) _onInfo(info);
    }
  }

  void _onReady() {
    if (_ready) return;
    _ready = true;
    for (final name in const ['onStateChange', 'onError']) {
      _post({
        'event': 'command',
        'func': 'addEventListener',
        'args': [name],
      });
    }
    final queued = List.of(_queued);
    _queued.clear();
    queued.forEach(_post);
    _events.add(const VideoReady());
  }

  void _onInfo(Map<dynamic, dynamic> info) {
    final time = info['currentTime'];
    if (time is num) {
      _position = Duration(milliseconds: (time * 1000).round());
      if (_playingSince != null) _playingSince = clock.now();
    }
    final state = info['playerState'];
    if (state is num) _onState(state);
  }

  void _onState(Object? raw) {
    if (raw is! num || raw.toInt() == _state) return;
    final state = _state = raw.toInt();
    _playingSince = state == 1 ? clock.now() : null;
    final event = switch (state) {
      0 => const VideoEnded(),
      1 => const VideoPlaying(),
      2 => const VideoPaused(),
      3 => const VideoBuffering(),
      _ => null,
    };
    if (event != null) _events.add(event);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _handshake?.cancel();
    web.window.removeEventListener('message', _onMessage);
    _frame.src = 'about:blank';
    await _events.close();
  }
}
