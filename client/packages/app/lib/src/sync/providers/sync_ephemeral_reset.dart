// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a fresh sync connection forgets because no catch-up can recover it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  // A missed voice.activity frame while disconnected is otherwise unrecoverable.
  ref.read(dmCallActivityProvider.notifier).clear();
  ref.read(dmCallRingControllerProvider.notifier).clear();
  // Same: typing.stopped is ephemeral, so one missed frame sticks forever.
  ref.invalidate(typingControllerProvider);
  // A watch tick is ephemeral too: the session may have moved on or ended while offline.
  ref.invalidate(watchRoomProvider);
  // Listens for private answers from here on; created lazily it would miss the first one.
  ref.read(ephemeralMessagesProvider);
}
