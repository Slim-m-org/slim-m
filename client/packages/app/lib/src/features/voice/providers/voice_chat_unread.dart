// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a voice channel's chat holds something unread, for every toggle that opens it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../channels/providers/channel_by_id_provider.dart';
import '../../channels/providers/channel_notification_overrides_controller.dart';
import '../../messages/providers/unread_indicator_rules.dart';

/// Whether the voice channel has text, or a mention, this device has not read.
final voiceChatUnreadProvider = Provider.autoDispose.family<bool, String>((
  ref,
  channelId,
) {
  final channel = ref.watch(channelByIdProvider(channelId)).valueOrNull;
  if (channel == null) return false;
  final override = ref.watch(
    channelNotificationOverridesProvider.select((s) => s.effectiveFor(channel)),
  );
  final indicator = unreadIndicatorForChannel(
    channel,
    channelOverride: override,
    isDm: false,
  );
  return indicator.unread || indicator.mentioned;
});
