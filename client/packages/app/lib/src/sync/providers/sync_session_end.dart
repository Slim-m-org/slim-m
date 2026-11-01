// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a session ending clears, whichever way it ended.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../features/channels/providers/channel_history.dart';
import '../../features/channels/providers/last_text_channel.dart';
import '../../features/members/providers/member_presence.dart';
import '../../features/members/providers/presence_activity.dart';
import '../../features/members/providers/presence_controller.dart';
import '../../features/members/providers/presence_devices.dart';
import '../../features/messages/providers/ephemeral_messages.dart';
import '../../features/messages/providers/message_extras.dart';
import '../../features/voice/providers/dm_call_activity.dart';
import '../../features/voice/providers/dm_call_ring_controller.dart';
import '../../features/voice/providers/voice_controller.dart';
import '../../providers/providers.dart';
import 'sync_failure.dart';
import 'sync_status.dart';

/// The session ended, whichever way: a sign-out, an account deletion that
/// went through, or a refresh the server rejected.
///
/// The local database is one file for the whole app, not one per account or
/// per server, so whatever survives here is read by whoever signs in next on
/// this device: the previous account's channel list and message text,
/// visible before any new sync could correct it. Phones get handed over and
/// desktops are shared, so the cache goes the moment it stops belonging to
/// the person holding the device.
///
/// Best-effort. A database that will not open or clear must not leave
/// somebody stuck signed in, so the failure is swallowed; the session is
/// already gone by the time this runs.
///
/// [channelHistoryProvider] and [messageExtrasProvider] are reset alongside
/// the database for the same reason; see their own doc comments.
///
/// The DM-call ring state is cleared here too, and that is not cosmetic:
/// see `sign_out_stops_the_ring_test.dart` for what a surviving ring does.
///
/// Leaving the voice call belongs here rather than only in the Sign Out
/// button, because a session can end without the user asking for it.
/// `SlimmApi._refreshOnce` clears the session on a 401 while refreshing -
/// an expired or revoked refresh token, or another device signing this
/// account out - and that path reaches this method without passing through
/// any UI. Until it did, an involuntary end left a live microphone
/// publishing into a room the app itself considered signed out of, until
/// the server's own 40-second stale-heartbeat sweep noticed. `leave()`
/// bumps its own call generation and is safe to call when not in a call,
/// so the explicit Sign Out path calling it first costs nothing here.
Future<void> clearSessionState(Ref ref) async {
  ref.invalidate(channelHistoryProvider);
  ref.invalidate(meProvider);
  ref.invalidate(initialSyncCompleteProvider);
  ref.invalidate(hasFailedSinceLiveProvider);
  ref.invalidate(syncFailureProvider);
  ref.invalidate(ephemeralMessagesProvider);
  ref.invalidate(lastTextChannelProvider);
  ref.invalidate(previousTextChannelProvider);
  ref.invalidate(deletedChannelsProvider);
  ref.read(messageExtrasProvider.notifier).clear();
  ref.read(dmCallRingControllerProvider.notifier).clear();
  ref.read(dmCallActivityProvider.notifier).clear();
  ref.read(presenceControllerProvider.notifier).clear();
  ref.read(presenceActivityProvider.notifier).clear();
  ref.read(presenceDevicesProvider.notifier).clear();
  ref.invalidate(presenceVisibilityDisplayProvider);
  ref.invalidate(memberProfileOverridesProvider);
  // A session can end without the user asking; see this method's own doc.
  unawaited(ref.read(voiceControllerProvider.notifier).leave());
  try {
    final store = await ref.read(storeProvider.future);
    await store.clear();
  } catch (error, stack) {
    AppLog.swallowed(
      LogTag.sync,
      'Could not clear local data after signing out',
      error,
      stack,
    );
  }
}
