// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a live message should alert on this device, shared by the chime
/// (`notification_sound_controller.dart`) and the desktop banner
/// (`desktop_message_notifier.dart`) so the two cannot drift apart again.
///
/// The steps are the server's own push gate, in the server's order: a message
/// from yourself, someone you blocked or an account that no longer exists
/// never alerts; the preference that applies is the channel's own override,
/// else the parent channel's for a thread, else the account's
/// (`COALESCE(c.preference, p.preference, u.notification_preference)` in
/// `channel_notification_prefs.rs`); and the notification schedule has the
/// last word.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../widgets/message_mentions.dart' show messageMentionsUsername;
import 'blocks_controller.dart';
import 'channel_notification_overrides_controller.dart';
import 'notification_preference_controller.dart';
import 'notification_schedule_controller.dart';
import 'notification_schedule_rules.dart';
import 'notification_sound_rules.dart';
import 'providers.dart';

/// What an alert needs to know about a message it was allowed to raise.
class MessageAlert {
  const MessageAlert({required this.isDm, required this.mentionsSelf});

  final bool isDm;
  final bool mentionsSelf;
}

final messageAlertPolicyProvider = Provider<MessageAlertPolicy>(
  MessageAlertPolicy.new,
);

class MessageAlertPolicy {
  MessageAlertPolicy(this._ref);

  final Ref _ref;

  /// Cached against the id it was resolved for, so a different account
  /// signing in on the same device never reuses a stale username.
  String? _selfUsername;
  String? _selfUsernameForId;

  /// A thread's parent channel never changes, so each is asked for once.
  final Map<String, String?> _parentChannels = {};

  /// The alert [message] earns, or null when it should stay quiet.
  Future<MessageAlert?> evaluate(api.Message message) async {
    final selfId = _ref.read(sessionProvider).tokens?.userId;
    if (!messageEarnsASound(
      authorId: message.authorId,
      selfId: selfId,
      authorBlocked: _ref.read(blocksProvider).contains(message.authorId),
    )) {
      return null;
    }

    final store = await _ref.read(storeProvider.future);
    final channel = await store.watchChannelRow(message.channelId).first;
    final isDm = channel?.kind == 'dm';
    final mentionsSelf = !isDm && await _mentionsSelf(message, selfId);

    final overrides = _ref.read(channelNotificationOverridesProvider);
    final preference =
        overrides.overrideFor(message.channelId) ??
        await _parentOverride(
          channel?.parentMessageId,
          message.channelId,
          overrides,
        ) ??
        await _accountPreference();
    if (!channelEarnsASound(
      channelOverride: preference,
      isDm: isDm,
      mentionsSelf: mentionsSelf,
    )) {
      return null;
    }

    final schedule = _ref.read(notificationScheduleProvider).valueOrNull;
    if (!scheduleEarnsASound(
      state: evaluateNotificationSchedule(schedule),
      channelAllowed:
          schedule?.allowedChannelIds.contains(message.channelId) ?? false,
      authorAllowed:
          schedule?.allowedUserIds.contains(message.authorId) ?? false,
      isDm: isDm,
      mentionsSelf: mentionsSelf,
    )) {
      return null;
    }
    return MessageAlert(isDm: isDm, mentionsSelf: mentionsSelf);
  }

  Future<bool> _mentionsSelf(api.Message message, String? selfId) async {
    if (selfId == null) return false;
    final username = await _resolveSelfUsername(selfId);
    return username != null &&
        messageMentionsUsername(message.content, username);
  }

  /// Best-effort: a lookup failure just leaves one message read as not a
  /// mention, and the next message that needs it tries again.
  Future<String?> _resolveSelfUsername(String selfId) async {
    if (_selfUsernameForId == selfId) return _selfUsername;
    try {
      _selfUsername = (await _ref.read(apiProvider).me()).username;
      _selfUsernameForId = selfId;
    } on api.ApiException {
      // Reads the unchanged, possibly null, cache.
    }
    return _selfUsername;
  }

  /// The override on a thread's parent channel, null for any other channel or
  /// when the parent cannot be found (the thread then follows the account).
  Future<api.NotificationPreference?> _parentOverride(
    String? parentMessageId,
    String channelId,
    ChannelNotificationOverridesState overrides,
  ) async {
    if (parentMessageId == null) return null;
    if (!_parentChannels.containsKey(channelId)) {
      try {
        final parent = await _ref.read(apiProvider).getThreadParent(channelId);
        _parentChannels[channelId] = parent.parentChannelId;
      } on api.ApiException {
        return null;
      }
    }
    final parentId = _parentChannels[channelId];
    return parentId == null ? null : overrides.overrideFor(parentId);
  }

  /// The account's own "Notify me for", null when it cannot be read, so a
  /// failure of any kind (including a body the client could not parse) never
  /// silences a message the person did not ask to silence.
  Future<api.NotificationPreference?> _accountPreference() async {
    try {
      return await _ref.read(notificationPreferenceProvider.future);
    } on Object {
      return null;
    }
  }
}
