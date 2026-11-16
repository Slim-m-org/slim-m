// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ScreenOverlay] over the runner's method channel (Linux GTK, Windows
/// layered window). Anywhere the runner has no handler it reports
/// unsupported, so the setting never offers what cannot work.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'screen_overlay.dart';

const screenOverlayChannelName = 'slimm/screen_overlay';

/// What the runner calls when the monitor layout changed under an open overlay window.
const screenOverlayDisplaysChanged = 'displaysChanged';

// One per channel for every instance: a second method call handler would replace the first.
final _displayNotices = <String, StreamController<void>>{};

StreamController<void> _displayNoticesOf(MethodChannel channel) =>
    _displayNotices.putIfAbsent(channel.name, () {
      late final StreamController<void> notices;
      notices = StreamController<void>.broadcast(
        onListen: () => channel.setMethodCallHandler((call) async {
          if (call.method == screenOverlayDisplaysChanged) notices.add(null);
        }),
        onCancel: () => channel.setMethodCallHandler(null),
      );
      return notices;
    });

class ChannelScreenOverlay implements ScreenOverlay {
  const ChannelScreenOverlay({
    MethodChannel channel = const MethodChannel(screenOverlayChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<OverlaySupport> support() async {
    try {
      return OverlaySupport.fromReply(
        await _channel.invokeMethod<Object>('support'),
      );
    } on MissingPluginException {
      return const OverlaySupport.unsupported();
    } on PlatformException {
      return const OverlaySupport.unsupported();
    }
  }

  @override
  Future<bool> show(List<int> monitors, {int? window}) async {
    try {
      return await _channel.invokeMethod<bool>('show', {
            'monitor': monitors.first,
            'monitors': monitors,
            if (window != null) 'window': window,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> draw(List<OverlayShape> shapes) async {
    try {
      await _channel.invokeMethod<void>('draw', {
        'shapes': [for (final s in shapes) s.toJson()],
      });
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<void> hide() async {
    try {
      await _channel.invokeMethod<void>('hide');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<void> panel(OverlayPanel? panel) async {
    try {
      await _channel.invokeMethod<void>('panel', panel?.toJson());
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  @override
  Stream<void> get displaysChanged => _displayNoticesOf(_channel).stream;

  @override
  Future<int?> appMonitor() async {
    try {
      final index = await _channel.invokeMethod<int>('appMonitor');
      return index == null || index < 0 ? null : index;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
