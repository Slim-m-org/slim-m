// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a live message should alert on this device, shared by the chime and the desktop banner so they cannot drift.
/// Follows the server's push gate in order: own, blocked or deleted senders never alert; then the channel override, else the parent's for a thread, else the account's; the notification schedule has the last word.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Channel;

import '../../../permissions.dart';
import '../../members/providers/blocks_controller.dart';
import '../../members/providers/user_profiles.dart';
import '../../channels/providers/channel_notification_overrides_controller.dart';
import '../../settings/providers/notification_preference_controller.dart';
import '../../settings/providers/notification_schedule_controller.dart';
import '../../settings/providers/notification_schedule_rules.dart';
import '../../settings/providers/notification_sound_rules.dart';
import '../../../providers/providers.dart';

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
/// A `var` so a test can shrink it.
@visibleForTesting
var alertRefreshWait = const Duration(seconds: 2);

final messageAlertPolicyProvider = Provider<MessageAlertPolicy>(
  MessageAlertPolicy.new,
);

class MessageAlertPolicy {
  MessageAlertPolicy(this._ref);

  final Ref _ref;

  /// Whether this account can post in each channel, for [_canSendIn].
  final Map<String, ({bool value, DateTime at})> _canSend = {};

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
    // The server resolves this per viewer, including role and broadcast rights the client cannot see.
    final mentionsSelf = !isDm && message.mentionsMe;

    final overrides = _ref.read(channelNotificationOverridesProvider);
    final parentId = await _parentChannelId(
      channel?.parentMessageId,
      message.channelId,
    );
    final preference =
        overrides.overrideFor(message.channelId) ??
        (parentId == null ? null : overrides.overrideFor(parentId)) ??
        stricterPreference(
          await _channelDefault(channel, parentId),
          await _accountDefaultIn(message, isDm: isDm),
        );
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

  /// A channel's own default, or its parent's for a thread: a thread has none
  /// of its own.
  Future<api.NotificationPreference?> _channelDefault(
    Channel? channel,
    String? parentId,
  ) async {
    if (parentId == null) {
      return channel == null ? null : channelDefaultOf(channel);
    }
    final store = await _ref.read(storeProvider.future);
    final parent = await store.watchChannelRow(parentId).first;
    return parent == null ? null : channelDefaultOf(parent);
  }

  /// A thread's parent channel, null for any other channel or when the parent
  /// cannot be found (the thread then follows the account).
  Future<String?> _parentChannelId(
    String? parentMessageId,
    String channelId,
  ) async {
    if (parentMessageId == null) return null;
    if (!_parentChannels.containsKey(channelId)) {
      try {
        final parent = await _ref.read(apiProvider).getThreadParent(channelId);
        _parentChannels[channelId] = parent.parentChannelId;
      } on api.ApiException catch (error, stack) {
        api.reportFailure(
          api.LogTag.ui,
          'look up the parent channel of a thread for alerts',
          error,
          stack,
        );
        return null;
      }
    }
    return _parentChannels[channelId];
  }

  /// The account default as it applies to [message]: "everything" reads as
  /// "mentions" where this account cannot post or when a bot or webhook wrote
  /// it (see [readOnlyDefault]).
  Future<api.NotificationPreference?> _accountDefaultIn(
    api.Message message, {
    required bool isDm,
  }) async {
    final account = await _accountPreference();
    if (isDm || !readOnlyDefaultApplies(account)) return account;
    return readOnlyDefault(
      account,
      canSend: await _canSendIn(message.channelId),
      automated: await _isAutomated(message),
    );
  }

  /// Whether a bot or webhook wrote [message]. A profile that cannot be
  /// resolved reads as a person, so a failed lookup never silences anything.
  Future<bool> _isAutomated(api.Message message) async {
    if (message.webhookUsername != null) return true;
    final authorId = message.authorId;
    if (authorId == null) return false;
    try {
      final profile = await _ref
          .read(batchProfilesControllerProvider.notifier)
          .profile(authorId)
          .timeout(alertRefreshWait);
      return profile != null && (profile.isBot || profile.isWebhook);
    } on Object catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.ui,
        'Could not tell whether a bot wrote a message; treating it as a person',
        error,
        stack,
      );
      return false;
    }
  }

  /// Whether this account can post in [channelId], cached for
  /// [alertStateMaxAge]. True when it cannot be read, so a failed lookup
  /// never silences anything.
  Future<bool> _canSendIn(String channelId) async {
    final cached = _canSend[channelId];
    if (cached != null &&
        DateTime.now().difference(cached.at) <= alertStateMaxAge) {
      return cached.value;
    }
    try {
      final perms = await _ref
          .read(apiProvider)
          .getChannelPermissions(channelId)
          .timeout(alertRefreshWait);
      final value = perms.hasPermission(Perm.sendMessages);
      _canSend[channelId] = (value: value, at: DateTime.now());
      return value;
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'check whether you can send in a channel',
        error,
        stack,
      );
      return cached?.value ?? true;
    }
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
      return await _ref.read(future).timeout(alertRefreshWait);
    } on Object catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.ui,
        'Could not read the notification setting in time; using the default',
        error,
        stack,
      );
      return _ref.exists(provider) ? _ref.read(provider).valueOrNull : null;
    }
  }
}
