// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a voice channel's chat holds something unread, for every toggle that opens it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../channels/providers/channel_by_id_provider.dart';
import '../../channels/providers/channel_notification_overrides_controller.dart';
import '../../messages/providers/unread_indicator_rules.dart';
import 'voice_flags.dart';

/// Whether the voice channel has text, or a mention, this device has not read.
/// Inside its call any message counts unless the chat is muted; outside, the chat's level decides as on the rail.
final voiceChatUnreadProvider = Provider.autoDispose.family<bool, String>((
  ref,
  channelId,
) {
  final channel = ref.watch(channelByIdProvider(channelId)).valueOrNull;
  if (channel == null) return false;
  final override = ref.watch(
    channelNotificationOverridesProvider.select((s) => s.effectiveFor(channel)),
  );
  final inCall = ref.watch(
    voiceFlagsProvider.select((voice) => voice.inCallStageFor(channelId)),
  );
  final muted = override == api.NotificationPreference.nothing;
  final indicator = unreadIndicatorForChannel(
    channel,
    channelOverride: inCall && !muted ? null : override,
    isDm: false,
  );
  return indicator.unread || indicator.mentioned;
});
