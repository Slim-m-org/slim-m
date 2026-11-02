// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Speaker or earpiece on a phone that has no output picker.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

/// Where LiveKit's process-wide audio manager is reached, so tests can stand in.
typedef SpeakerApply = Future<void> Function(bool preferred);

/// The loudspeaker-versus-earpiece choice. Android lists real outputs in its
/// picker; iOS lists none, so this is the one routing control it has.
class SpeakerRoute {
  SpeakerRoute({bool? supported, SpeakerApply? apply})
      : _supported = supported,
        _apply = apply ?? _applyToLiveKit;

  final bool? _supported;
  final SpeakerApply _apply;

  /// Capability, not shape: true where the platform can switch speakerphone
  /// yet AudioDeviceSwitching.supportsOutputSelection offers no picker.
  bool get supported =>
      _supported ??
      (lk.AudioManager.instance.canSwitchSpeakerphone &&
          lk.lkPlatformIs(lk.PlatformType.iOS));

  /// [preferred] chooses the loudspeaker; a connected headset still wins.
  Future<void> set(bool preferred) async {
    if (supported) await _apply(preferred);
  }

  static Future<void> _applyToLiveKit(bool preferred) =>
      lk.AudioManager.instance.setSpeakerOutputPreferred(preferred);
}
