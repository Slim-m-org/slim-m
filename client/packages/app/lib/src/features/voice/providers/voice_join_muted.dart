// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens the mic off in a channel that asks for it, without losing the
/// member's own sticky mic preference.
///
/// `VoiceState.microphoneEnabled` is that preference between calls, so a
/// join_muted channel only shows it as off for the length of the call and
/// this remembers to put it back. Only an on preference is ever replaced, so
/// what is remembered is always "on", whatever the member does in the call.
///
/// Its own file to keep `voice_controller.dart` under the line budget.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import '../../../providers/providers.dart';
import 'voice_state.dart';

class VoiceJoinMuted {
  bool _restoreOn = false;

  /// Whether [channelId] asks members to join with the mic off. Waits for the
  /// local store to open; false when it fails or does not know the channel.
  Future<bool> asksFor(Ref ref, String channelId) async {
    try {
      final store = await ref.read(storeProvider.future);
      final row = await store.channelRow(channelId);
      return row?.joinMuted ?? false;
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'Could not read the join muted setting',
        error,
        stack,
      );
      return false;
    }
  }

  /// The mic preference a join starts from, undoing the previous call's mute.
  bool preferenceAtJoin(bool current) => _take() || current;

  /// [call] with the mic shown off, remembering the preference it replaces.
  VoiceState showMuted(VoiceState call) {
    // Kept when already set: a call that comes back muted is shown muted a second time.
    _restoreOn = _restoreOn || call.microphoneEnabled;
    return call.copyWith(microphoneEnabled: false, joinedMuted: true);
  }

  /// The preference to carry out of a call that ends with [current] shown.
  bool preferenceAtLeave(bool current) => _take() || current;

  bool _take() {
    final restore = _restoreOn;
    _restoreOn = false;
    return restore;
  }
}
