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
/// `channel_notification_prefs.rs`), with an "everything" account default
/// read as "mentions" in a channel this account cannot post in or for a post
/// by a bot or webhook; and the notification
/// schedule has the last word.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Channel;

import '../../../permissions.dart';
import '../widgets/message_mentions.dart' show messageMentionsMe;
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

/// How long a failed lookup of this account's name and roles waits before the
/// next message may try again. A `var` so a test can shrink it.
@visibleForTesting
var selfLookupRetryAfter = const Duration(seconds: 30);

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
  DateTime? _selfFailedAt;
  String? _selfFailedForId;
  String? _selfLookupForId;
  Future<({String username, List<String> roles})?>? _selfLookup;

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
    final mentionsSelf = !isDm && await _mentionsSelf(message, selfId);

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

  /// Best-effort: a lookup failure just leaves messages read as not a mention
  /// until [selfLookupRetryAfter] passes. A burst of messages shares one
  /// lookup and a failure is not retried per message, since `/me` shares the
  /// per-user read budget and a 429 there blanks the user panel.
  Future<({String username, List<String> roles})?> _resolveSelf(String selfId) {
    final now = DateTime.now();
    final loadedAt = _selfAt;
    final fresh =
        _selfForId == selfId &&
        loadedAt != null &&
        now.difference(loadedAt) <= alertStateMaxAge;
    final failedAt = _selfFailedAt;
    // Scoped to the account that failed, so signing in as another one looks it up straight away.
    final backingOff =
        _selfFailedForId == selfId &&
        failedAt != null &&
        now.difference(failedAt) < selfLookupRetryAfter;
    if (fresh || backingOff) {
      return Future.value(_selfForId == selfId ? _self : null);
    }
    final inFlight = _selfLookup;
    if (inFlight != null && _selfLookupForId == selfId) return inFlight;
    _selfLookupForId = selfId;
    final lookup = _lookUpSelf(selfId);
    _selfLookup = lookup;
    return lookup.whenComplete(() {
      if (identical(_selfLookup, lookup)) _selfLookup = null;
    });
  }

  Future<({String username, List<String> roles})?> _lookUpSelf(
    String selfId,
  ) async {
    try {
      final client = _ref.read(apiProvider);
      final me = await client.me();
      _self = (username: me.username, roles: await _roleNames(client, selfId));
      _selfForId = selfId;
      _selfAt = DateTime.now();
      _selfFailedAt = null;
      _selfFailedForId = null;
    } on api.ApiException catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'look up who you are for mention alerts',
        error,
        stack,
      );
      // Keeps the cache for this account, if there is one.
      _selfFailedAt = DateTime.now();
      _selfFailedForId = selfId;
    }
    return _selfForId == selfId ? _self : null;
  }

  /// Only `@[Role]` mentions need these, so a profile that cannot be read
  /// costs that and nothing else.
  Future<List<String>> _roleNames(api.SlimmApi client, String selfId) async {
    try {
      return (await client.getUser(selfId)).roles;
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'look up your roles for mention alerts',
        error,
        stack,
      );
      return const [];
    }
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
          .timeout(_refreshWait);
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
          .timeout(_refreshWait);
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
      return await _ref.read(future).timeout(_refreshWait);
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
