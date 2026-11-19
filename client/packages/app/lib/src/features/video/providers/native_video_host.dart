// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop runners' YouTube host: a native webview (WebKitGTK on Linux,
/// WebView2 on Windows) floating over the Flutter view at a rect Dart sets.
/// The C++ halves are `linux/runner/youtube_player_channel.cc` and
/// `windows/runner/youtube_player_channel.cpp`.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'docked_video_player.dart';
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

  /// Builds the hidden view and loads the host page into it.
  Future<bool> create(void Function(String message) onMessage) async {
    _onMessage = onMessage;
    try {
      return await _channel.invokeMethod<bool>('create', {
            'html': youtubeHostHtml,
            'url': kYoutubeHostUrl,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> setBounds(NativeViewRect rect) => _invoke('setBounds', {
    'x': rect.x,
    'y': rect.y,
    'width': rect.width,
    'height': rect.height,
  });

  Future<void> setVisible(bool visible) =>
      _invoke('setVisible', {'visible': visible});

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

/// The player inside the docked panel on desktop.
class NativeDockedPlayer extends YoutubeBridgePlayer
    implements DockedVideoPlayer {
  NativeDockedPlayer(this.host);

  final NativeVideoHost host;
  Future<bool>? _created;

  /// Creates the native view on first use; every command waits for it.
  Future<bool> _ensureCreated() => _created ??= host.create(handleMessage);

  @override
  Future<void> runScript(String script) async {
    if (await _ensureCreated()) await host.run(script);
  }

  @override
  Future<void> setBounds(NativeViewRect rect) async {
    if (await _ensureCreated()) await host.setBounds(rect);
  }

  @override
  Future<void> setVisible(bool visible) async {
    if (await _ensureCreated()) await host.setVisible(visible);
  }

  @override
  Future<void> disposeHost() async {
    if (_created != null) await host.destroy();
  }
}
