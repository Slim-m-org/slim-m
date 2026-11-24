// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the "join with camera on" setting off the live camera state while a
/// call is open.
///
/// `VoiceState.cameraEnabled` is the live truth in a call and the carried
/// preference between calls. The saved setting lives here, so a call that
/// ends hands back the setting rather than the camera it ended with.
///
/// Its own file to keep `voice_controller.dart` under the line budget.
library;

import 'voice_state.dart';

class VoiceCameraPreference {
  bool _preference = false;

  /// [call] with [enabled] applied, or held until the call ends when one is open.
  VoiceState apply(VoiceState call, bool enabled) {
    _preference = enabled;
    if (call.channelId != null) return call;
    return call.copyWith(cameraEnabled: enabled);
  }

  /// The saved preference, which a call that ends carries into the next one.
  bool atLeave() => _preference;
}
