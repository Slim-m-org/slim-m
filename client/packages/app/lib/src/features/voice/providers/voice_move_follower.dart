// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Follows the server's word that this account's call moved: a moderator's
/// move joins the destination and says who did it, and a call taken over by
/// another device of the account says so instead of a bare removal.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/toasts.dart';
import 'voice_controller.dart';

class VoiceMoveFollower {
  VoiceMoveFollower(this._ref) {
    final sub = _ref.read(liveEventsProvider).listen(_onEvent);
    _ref.onDispose(() => unawaited(sub.cancel()));
  }

  final Ref _ref;

  void _onEvent(api.ServerEvent event) {
    if (event is api.VoiceRemoved &&
        event.reason == api.VoiceRemovalReason.otherDevice) {
      _ref
          .read(voiceControllerProvider.notifier)
          .noteMovedAway(event.channelId);
    }
    if (event is! api.VoiceMoved) return;
    final controller = _ref.read(voiceControllerProvider.notifier);
    // Another device of this account may be the one in that call.
    if (_ref.read(voiceControllerProvider).channelId != event.fromChannelId) {
      return;
    }
    unawaited(controller.joinMoved(event.toChannelId));
    _ref
        .read(toastsProvider.notifier)
        .show('${event.movedByName} moved you to ${event.toChannelName}.');
  }
}

/// Watched from the signed-in shell so it lives for the session.
final voiceMoveFollowerProvider = Provider<VoiceMoveFollower>(
  (ref) => VoiceMoveFollower(ref),
);
