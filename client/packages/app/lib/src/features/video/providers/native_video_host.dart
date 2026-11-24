// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop runners' YouTube host: a native webview (WebKitGTK on Linux,
/// WebView2 on Windows) kept off screen, its frames handed to Flutter as a
/// texture. The C++ halves are `linux/runner/youtube_player_channel.cc` and
/// `windows/runner/youtube_player_channel.cpp`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart';

import 'desktop_video_player.dart';
import 'youtube_bridge_player.dart';
import 'youtube_host_page.dart';

/// The process's one native player view. Every account's player shares this
/// host, so the view has one owner at a time and the others hear when they
/// lose it.
class NativeVideoHost {
  NativeVideoHost([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'top.npcserver.slimm/youtube_player';

  final MethodChannel _channel;
  bool _handling = false;
  Object? _owner;
  void Function(String message)? _onMessage;
  void Function()? _onDisplaced;

  /// Whether this build and machine can host the player at all: false with
  /// no runner support, or with the webview library missing at run time.
  Future<bool> probe() async {
    try {
      return await _channel.invokeMethod<bool>('probe') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Builds the view for [owner], displacing whoever held it, loads the host
  /// page into it and answers the texture its frames go to, or null when the
  /// view could not be built or [owner] lost it again meanwhile.
  Future<int?> create(
    Object owner, {
    required void Function(String message) onMessage,
    required void Function() onDisplaced,
  }) async {
    _listen();
    final previous = _onDisplaced;
    final displaced = _owner != null && !identical(_owner, owner);
    _owner = owner;
    _onMessage = onMessage;
    _onDisplaced = onDisplaced;
    if (displaced) previous?.call();
    try {
      final id = await _channel.invokeMethod<int>('create', {
        'html': youtubeHostHtml,
        'url': kYoutubeHostUrl,
      });
      if (!identical(_owner, owner)) return null;
      return id == null || id < 0 ? null : id;
    } on PlatformException {
      return null;
    }
  }

  Future<void> resize(Object owner, Size size, double pixelRatio) => _invoke(
    owner,
    'resize',
    {'width': size.width, 'height': size.height, 'pixelRatio': pixelRatio},
  );

  Future<void> pointer(Object owner, VideoPointerKind kind, Offset position) =>
      _invoke(owner, 'pointer', {
        'kind': kind.name,
        'x': position.dx,
        'y': position.dy,
        'button': 1,
      });

  Future<void> run(Object owner, String script) =>
      _invoke(owner, 'run', {'script': script});

  /// Releases the view when [owner] still holds it; a displaced owner has
  /// nothing left to release.
  Future<void> destroy(Object owner) async {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _onMessage = null;
    _onDisplaced = null;
    await _send('destroy', null);
  }

  void _listen() {
    if (_handling) return;
    _handling = true;
    _channel.setMethodCallHandler(_onCall);
  }

  Future<void> _invoke(Object owner, String method, Object? args) async {
    if (identical(_owner, owner)) await _send(method, args);
  }

  Future<void> _send(String method, Object? args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'message' && call.arguments is String) {
      _onMessage?.call(call.arguments as String);
    }
    return null;
  }
}

/// One account's desktop player, over the shared [NativeVideoHost].
class TextureVideoPlayer extends YoutubeBridgePlayer
    implements DesktopVideoPlayer {
  TextureVideoPlayer(this.host);

  final NativeVideoHost host;

  final _texture = ValueNotifier<int?>(null);
  final _displaced = StreamController<void>.broadcast();
  Future<bool>? _created;
  bool _lost = false;

  @override
  ValueListenable<int?> get texture => _texture;

  @override
  Stream<void> get displaced => _displaced.stream;

  /// Creates the native view on first use; every command waits for it.
  Future<bool> _ensureCreated() => _created ??= _create();

  Future<bool> _create() async {
    final id = await host.create(
      this,
      onMessage: handleMessage,
      onDisplaced: _loseView,
    );
    if (_lost) return false;
    if (id == null) {
      reportHostFailure();
      return false;
    }
    _texture.value = id;
    return true;
  }

  void _loseView() {
    _lost = true;
    _texture.value = null;
    _displaced.add(null);
  }

  /// Builds the view now, so the page can come up with no view on screen yet.
  @override
  Future<void> load(String videoId, {Duration start = Duration.zero}) {
    unawaited(_ensureCreated());
    return super.load(videoId, start: start);
  }

  @override
  Future<void> runScript(String script) async {
    if (await _ensureCreated()) await host.run(this, script);
  }

  @override
  Future<void> resize(Size size, double pixelRatio) async {
    if (await _ensureCreated()) await host.resize(this, size, pixelRatio);
  }

  @override
  Future<void> pointer(VideoPointerKind kind, Offset position) async {
    if (await _ensureCreated()) await host.pointer(this, kind, position);
  }

  @override
  Future<void> disposeHost() async {
    _texture.value = null;
    await _displaced.close();
    if (_created != null) await host.destroy(this);
  }
}
