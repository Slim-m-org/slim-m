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

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../widgets/message_mentions.dart' show messageMentionsMe;
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

/// How old the schedule and the account preference may be before an alert
/// refetches them. A snooze or a changed preference set on another device while
/// this one stays connected arrives as nothing at all, so this bounds how long
/// the desktop keeps chiming through it. A `var` so a test can shrink it.
@visibleForTesting
var alertStateMaxAge = const Duration(minutes: 1);

/// How long an alert waits for that refetch before it uses what it already has.
const _refreshWait = Duration(seconds: 2);

final messageAlertPolicyProvider = Provider<MessageAlertPolicy>(
  MessageAlertPolicy.new,
);

class MessageAlertPolicy {
  MessageAlertPolicy(this._ref);

  final Ref _ref;

  /// This account's username and role names, cached against the id they were
  /// resolved for (so another account signing in on the same device never
  /// reuses them) and refetched once older than [alertStateMaxAge], since roles
  /// change.
  ({String username, List<String> roles})? _self;
  String? _selfForId;
  DateTime? _selfAt;

  /// A thread's parent channel never changes, so each is asked for once.
  final Map<String, String?> _parentChannels = {};

  /// When each provider was last known good, for [alertStateMaxAge].
  final Map<Object, DateTime> _loadedAt = {};

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

    final schedule = await _current(
      notificationScheduleProvider,
      notificationScheduleProvider.future,
    );
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
    final me = await _resolveSelf(selfId);
    return me != null &&
        messageMentionsMe(
          message.content,
          username: me.username,
          roleNames: me.roles,
        );
  }

  /// Best-effort: a lookup failure just leaves one message read as not a
  /// mention, and the next message that needs it tries again.
  Future<({String username, List<String> roles})?> _resolveSelf(
    String selfId,
  ) async {
    final loadedAt = _selfAt;
    final fresh =
        _selfForId == selfId &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) <= alertStateMaxAge;
    if (fresh) return _self;
    try {
      final client = _ref.read(apiProvider);
      final me = await client.me();
      _self = (username: me.username, roles: await _roleNames(client, selfId));
      _selfForId = selfId;
      _selfAt = DateTime.now();
    } on api.ApiException {
      // Keeps the cache for this account, if there is one.
    }
    return _selfForId == selfId ? _self : null;
  }

  /// Only `@[Role]` mentions need these, so a profile that cannot be read
  /// costs that and nothing else.
  Future<List<String>> _roleNames(api.SlimmApi client, String selfId) async {
    try {
      return (await client.getUser(selfId)).roles;
    } on Object {
      return const [];
    }
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
  Future<api.NotificationPreference?> _accountPreference() => _current(
    notificationPreferenceProvider,
    notificationPreferenceProvider.future,
  );

  /// [provider]'s value, refetched first when it failed or is older than
  /// [alertStateMaxAge]. Falls back to whatever it holds if the refetch is
  /// slow or fails, so a bad network never silences or floods an alert.
  Future<T?> _current<T>(
    ProviderBase<AsyncValue<T>> provider,
    Refreshable<Future<T>> future,
  ) async {
    final now = DateTime.now();
    final loadedAt = _loadedAt[provider] ?? now;
    final failed = _ref.exists(provider) && _ref.read(provider).hasError;
    if (failed || now.difference(loadedAt) > alertStateMaxAge) {
      _ref.invalidate(provider);
      _loadedAt[provider] = now;
    } else {
      _loadedAt[provider] = loadedAt;
    }
    try {
      return await _ref.read(future).timeout(_refreshWait);
    } on Object {
      return _ref.exists(provider) ? _ref.read(provider).valueOrNull : null;
    }
  }
}
