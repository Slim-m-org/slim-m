// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ScreenOverlay] over the runner's method channel (Linux GTK, Windows
/// layered window). Anywhere the runner has no handler it reports
/// unsupported, so the setting never offers what cannot work.
library;

import 'package:flutter/services.dart';

import 'screen_overlay.dart';

const screenOverlayChannelName = 'slimm/screen_overlay';

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
  Future<bool> show(int monitor) async {
    try {
      return await _channel.invokeMethod<bool>('show', {'monitor': monitor}) ??
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
}
