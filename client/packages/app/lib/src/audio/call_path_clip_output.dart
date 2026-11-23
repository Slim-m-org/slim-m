// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A soundboard clip on iPhone during a call, played by the app's own audio
/// engine inside the call's session instead of by a plugin that resets it.
library;

import 'package:flutter/services.dart';

import 'sound_clip_player.dart';

const soundClipChannelName = 'top.npcserver.slimm/sound_clip';

class CallPathSoundClipPlayer implements SoundClipPlayer {
  CallPathSoundClipPlayer({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(soundClipChannelName);

  final MethodChannel _channel;

  @override
  Future<void> play(
    Uint8List bytes, {
    required String mimeType,
    required double volume,
  }) => _channel.invokeMethod<void>('play', {
    'bytes': bytes,
    'extension': clipFileExtension(mimeType),
    'volume': volume,
  });
}

/// The server accepts only mp3 and wav clips (decision 0118).
String clipFileExtension(String mimeType) =>
    mimeType.contains('wav') ? 'wav' : 'mp3';
