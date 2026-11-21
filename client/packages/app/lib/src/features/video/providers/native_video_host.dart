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

class NativeVideoHost {
  NativeVideoHost([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const channelName = 'top.npcserver.slimm/youtube_player';

  final MethodChannel _channel;
  void Function(String message)? _onMessage;

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

  /// Builds the view, loads the host page into it and answers the texture
  /// its frames go to, or null when the view could not be built.
  Future<int?> create(void Function(String message) onMessage) async {
    _onMessage = onMessage;
    try {
      final id = await _channel.invokeMethod<int>('create', {
        'html': youtubeHostHtml,
        'url': kYoutubeHostUrl,
      });
      return id == null || id < 0 ? null : id;
    } on PlatformException {
      return null;
    }
  }

  Future<void> resize(Size size, double pixelRatio) => _invoke('resize', {
    'width': size.width,
    'height': size.height,
    'pixelRatio': pixelRatio,
  });

  Future<void> pointer(VideoPointerKind kind, Offset position) => _invoke(
    'pointer',
    {'kind': kind.name, 'x': position.dx, 'y': position.dy, 'button': 1},
  );

  Future<void> run(String script) => _invoke('run', {'script': script});

  Future<void> destroy() async {
    _onMessage = null;
    await _invoke('destroy', null);
  }

  Future<void> _invoke(String method, Object? args) async {
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

/// The app's one desktop player, over [NativeVideoHost].
class TextureVideoPlayer extends YoutubeBridgePlayer
    implements DesktopVideoPlayer {
  TextureVideoPlayer(this.host);

  final NativeVideoHost host;

  final _texture = ValueNotifier<int?>(null);
  Future<bool>? _created;

  @override
  ValueListenable<int?> get texture => _texture;

  /// Creates the native view on first use; every command waits for it.
  Future<bool> _ensureCreated() => _created ??= _create();

  Future<bool> _create() async {
    final id = await host.create(handleMessage);
    if (id == null) {
      reportHostFailure();
      return false;
    }
    _texture.value = id;
    return true;
  }

  @override
  Future<void> runScript(String script) async {
    if (await _ensureCreated()) await host.run(script);
  }

  @override
  Future<void> resize(Size size, double pixelRatio) async {
    if (await _ensureCreated()) await host.resize(size, pixelRatio);
  }

  @override
  Future<void> pointer(VideoPointerKind kind, Offset position) async {
    if (await _ensureCreated()) await host.pointer(kind, position);
  }

  @override
  Future<void> disposeHost() async {
    _texture.value = null;
    if (_created != null) await host.destroy();
  }
}
