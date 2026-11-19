// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a sync connection does the moment it goes live.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart';

import '../../features/auth/providers/account_state_refresh.dart';
import '../../features/channels/providers/mounted_channels.dart';
import '../../features/channels/providers/open_channel_rehydrate.dart';
import '../../features/channels/providers/pins_controller.dart';
import '../../features/messages/providers/failed_send_retry.dart';
import '../../providers/admin_providers.dart';
import '../../providers/server_info.dart';
import 'sync_ephemeral_reset.dart';
import 'sync_failure.dart';
import 'sync_status.dart';

/// Refreshes what a reconnect may have missed, permissions included, clears the failure flags and
/// resends unsent messages.
void afterSyncLive(
  Ref ref,
  MessageStore store, {
  required bool reconnect,
  required bool Function() isCurrent,
}) {
  refreshAccountNotificationState(ref, reconnect: reconnect);
  if (reconnect) {
    refreshRosterAfterReconnect(ref);
    refreshPermissionsAfterReconnect(ref);
    rehydrateOpenChannels(ref.read);
    _rereadOpenPins(ref);
  }
  refreshPresenceOnLive(ref);
  refreshServerInfo(ref, reconnect: reconnect);
  ref.read(hasFailedSinceLiveProvider.notifier).state = false;
  ref.read(syncFailureProvider.notifier).state = null;
  // A DB read failure here must not read as this connect itself having failed; retryMessage's own catch already covers a failed resend.
  unawaited(
    retryFailedSends(
      ref.read,
      store,
      isCurrent: isCurrent,
    ).catchError(ignoreError(LogTag.sync, 'resend unsent messages')),
  );
}

/// Pin frames are never replayed, so a channel that stayed open rereads its pins.
void _rereadOpenPins(Ref ref) {
  for (final id in ref.read(mountedChannelsProvider).openChannelIds) {
    final pins = pinsControllerProvider(id);
    if (ref.exists(pins)) unawaited(ref.read(pins.notifier).refresh());
  }
}
