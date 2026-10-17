// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the "join with camera on" setting off the live camera state while a
/// call is open.
///
/// `VoiceState.cameraEnabled` is the live truth in a call and the carried
/// preference between calls. A setting changed mid-call is held here until
/// the call ends, the way [VoiceJoinMuted] holds its mic preference.
///
/// Its own file to keep `voice_controller.dart` under the line budget.
library;

import 'voice_state.dart';

class VoiceCameraPreference {
  bool? _heldForLeave;

  /// [call] with [enabled] applied, or held for [atLeave] when a call is open.
  VoiceState apply(VoiceState call, bool enabled) {
    if (call.channelId != null) {
      _heldForLeave = enabled;
      return call;
    }
    return call.copyWith(cameraEnabled: enabled);
  }

  /// The camera preference to carry out of a call that ends with [current].
  bool atLeave(bool current) {
    final held = _heldForLeave ?? current;
    _heldForLeave = null;
    return held;
  }
}
