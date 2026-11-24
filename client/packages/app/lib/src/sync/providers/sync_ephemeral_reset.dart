// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a fresh sync connection forgets because no catch-up can recover it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/members/providers/member_presence.dart';
import '../../features/members/providers/presence_controller.dart';
import '../../features/members/providers/user_profiles.dart';
import '../../features/messages/providers/ephemeral_messages.dart';
import '../../features/messages/providers/typing_controller.dart';
import '../../features/voice/providers/dm_call_activity.dart';
import '../../features/voice/providers/dm_call_ring_controller.dart';
import '../../features/voice/providers/watch_room.dart';

/// Clears per-connection ephemeral state; a missed frame of it is otherwise stuck.
void resetEphemeralSessionState(Ref ref) {
  // No cursor over a rename to catch up from, so forget every cached name on a fresh connect.
  ref.read(batchProfilesControllerProvider.notifier).clear();
  // A ring is re-read once live; see DmCallRingController.holdForReconnect.
  ref.read(dmCallRingControllerProvider.notifier).holdForReconnect();
  // Same: typing.stopped is ephemeral, so one missed frame sticks forever.
  ref.invalidate(typingControllerProvider);
  // A watch tick is ephemeral too: the session may have moved on or ended while offline.
  ref.invalidate(watchRoomProvider);
  // Listens for private answers from here on; created lazily it would miss the first one.
  ref.read(ephemeralMessagesProvider);
}

/// Re-asks for the roster a dropped socket may have left stale, once it is
/// live again: a profile edit made meanwhile is not replayed.
void refreshRosterAfterReconnect(Ref ref) {
  if (ref.exists(memberProfileOverridesProvider)) {
    ref.read(memberProfileOverridesProvider.notifier).clear();
  }
  ref.invalidate(membersProvider);
  ref.invalidate(channelMembersProvider);
}

/// Re-reads DM call state once the socket is subscribed: neither a
/// voice.activity nor a call.ringing frame missed while disconnected is replayed.
void refreshDmCallsOnLive(Ref ref) {
  ref.read(dmCallActivityProvider.notifier).resync();
  unawaited(ref.read(dmCallRingControllerProvider.notifier).restoreAfterLive());
}

/// Re-asks for every presence already shown, once a socket is live: a member
/// who came or went before it subscribed is never announced to it, and the
/// first connect of a launch is no exception, since the roster seeds first.
void refreshPresenceOnLive(Ref ref) {
  if (!ref.exists(presenceControllerProvider)) return;
  unawaited(ref.read(presenceControllerProvider.notifier).resync());
}
