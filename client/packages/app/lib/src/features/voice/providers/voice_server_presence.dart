// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Passes the server's word on who joined or left this call to the session.
///
/// The SFU tells the call about someone who never published (a muted joiner)
/// up to 3 s late, while the server hears it from its webhook at once.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/live_events.dart';
import 'voice_controller.dart';
import 'voice_state_access.dart';

class VoiceServerPresence {
  VoiceServerPresence(this._session, this._access);

  final VoiceSession _session;
  final VoiceStateAccess _access;

  void apply(api.ServerEvent event) {
    final channelId = _access.state.channelId;
    if (channelId == null) return;
    switch (event) {
      case api.VoiceParticipantLeft(:final userId)
          when event.channelId == channelId:
        _session.participantLeftByServer(userId);
      case api.VoiceParticipantJoined(:final userId)
          when event.channelId == channelId:
        _session.participantJoinedByServer(userId);
      default:
    }
  }
}

/// Watched from the signed-in shell so it lives for the session.
final voiceServerPresenceProvider = Provider<void>((ref) {
  final sub = ref.read(liveEventsProvider).listen((event) {
    if (event is! api.VoiceParticipantLeft &&
        event is! api.VoiceParticipantJoined) {
      return;
    }
    ref.read(voiceControllerProvider.notifier).serverPresence.apply(event);
  });
  ref.onDispose(() => unawaited(sub.cancel()));
});
