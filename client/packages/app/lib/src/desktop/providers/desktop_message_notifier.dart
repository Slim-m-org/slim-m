// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Desktop and web: posts an OS or browser notification when a message arrives
/// while the window or tab is not in the foreground.
///
/// The desktop has no remote push - nothing wakes a closed app the way FCM or
/// APNs wakes a phone - so the only notifications it can show are for messages
/// that arrive over the live socket while the app is running. This turns those
/// into OS notifications through [LocalNotifications.show]; on Android and
/// iOS the platform push already
/// does this, so this stays inert there.
///
/// Each conversation files under its own notification id, so a burst in one
/// collapses and a second conversation keeps its banner. What a reconnect's
/// catch-up stored never came as a live frame, so its DMs and mentions get one
/// summary banner per conversation.
///
/// Also flashes the Windows taskbar button until the window is focused.
///
/// Only when the window is not focused. A focused desktop app shows its own
/// unread state in the rail, and a second OS banner on top of the channel you
/// are already reading is noise, not news. Own messages are skipped for the
/// reason their name gives.
///
/// The channel's own override runs through [channelEarnsASound], the gate the
/// chime already uses and the rule the server's
/// `narrow_for_notification_preference` enforces for push. This path used to
/// read only the mute half of it, so a channel narrowed to mentions kept
/// raising a banner for every ordinary message while the chime beside it
/// stayed silent.
///
/// Also gated by the notification schedule (`notification_schedule_rules.dart`),
/// the same policy `notification_sound_controller.dart` already applies to
/// the chime - the owner's own instruction was that both foreground paths
/// honour it, not only the one with a sound attached.
///
/// Read once from bootstrap, beside the sync and push controllers, so the
/// subscription lives for the whole signed-in session.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';

import '../../features/accounts/providers/account_slot.dart';
import '../../features/accounts/providers/notification_target.dart';
import 'desktop_message_text_settings.dart';
import 'desktop_notification_text.dart';
import '../../providers/app_lifecycle.dart';
import '../../providers/live_events.dart';
import '../../features/members/providers/member_presence.dart'
    show memberProfileOverridesProvider, membersProvider;
import '../../features/members/providers/mention_names.dart'
    show mentionNamesFrom;
import '../../features/messages/providers/message_alert_policy.dart';
import '../../providers/providers.dart';
import '../../push/android_push_messages.dart' show previewNotificationId;
import '../../push/providers/push_controller.dart';

final desktopMessageNotifierProvider = Provider<void>((ref) {
  // Android and iOS notify from platform push; only the desktop and a browser tab need this.
  if (!isDesktopHost && !kIsWeb) return;

  // Kept alive so an alert reads the roster from memory instead of refetching it.
  ref.listen(membersProvider, (_, _) {});
  final notifier = _DesktopMessageNotifier(ref);
  final subs = [
    ref.read(liveEventsProvider).listen(notifier.onServerEvent),
    ref.read(caughtUpMessagesProvider).listen(notifier.onCaughtUp),
  ];
  ref.onDispose(() {
    notifier.disposed = true;
    for (final sub in subs) {
      unawaited(sub.cancel());
    }
  });
});

class _DesktopMessageNotifier {
  _DesktopMessageNotifier(this._ref);

  final Ref _ref;

  /// Set when the account container goes away, so work in flight stops touching it.
  bool disposed = false;

  void onServerEvent(api.ServerEvent event) {
    if (event case api.MessageCreated(:final message)) {
      unawaited(
        _guarded('announce a message', () => _onMessageCreated(message)),
      );
    }
  }

  void onCaughtUp(List<api.Message> messages) => unawaited(
    _guarded('announce missed messages', () => _announceMissed(messages)),
  );

  Future<void> _guarded(String what, Future<void> Function() body) async {
    try {
      await body();
    } catch (error, stack) {
      if (disposed) return;
      api.AppLog.swallowed(
        api.LogTag.platform,
        'Could not $what',
        error,
        stack,
      );
    }
  }

  /// Whether the person is looking at this account, so the rail already shows its unread.
  bool get _watching =>
      _ref.read(appFocusedProvider) && _ref.read(accountActiveProvider);

  Future<void> _onMessageCreated(api.Message message) async {
    // Skip while focused: a foreground app shows unread in the rail already, but only for the account on screen.
    if (_watching) return;

    final alert = await _ref.read(messageAlertPolicyProvider).evaluate(message);
    if (alert == null || disposed) return;
    final text = await _textFor(message, isDm: alert.isDm);
    if (disposed) return;
    _present(text, message.channelId, mentionsSelf: alert.mentionsSelf);
  }

  /// One banner per conversation for what a reconnect's catch-up stored: only DMs and mentions, as a missed ordinary message is not worth waking anyone.
  Future<void> _announceMissed(List<api.Message> messages) async {
    if (_watching) return;
    final missed = <String, List<api.Message>>{};
    final mentioned = <String>{};
    for (final message in messages) {
      final alert = await _ref
          .read(messageAlertPolicyProvider)
          .evaluate(message);
      if (disposed) return;
      if (alert == null || !(alert.isDm || alert.mentionsSelf)) continue;
      (missed[message.channelId] ??= []).add(message);
      if (alert.mentionsSelf) mentioned.add(message.channelId);
    }
    for (final MapEntry(key: channelId, value: held) in missed.entries) {
      final latest = held.last;
      final text = await _textFor(latest, isDm: !mentioned.contains(channelId));
      if (disposed) return;
      final summary = held.length == 1
          ? text
          : (
              title: text.title,
              body: mentioned.contains(channelId)
                  ? '${held.length} new messages, with a mention'
                  : '${held.length} new messages',
            );
      _present(summary, channelId, mentionsSelf: mentioned.contains(channelId));
    }
  }

  Future<({String? title, String body})> _textFor(
    api.Message message, {
    required bool isDm,
  }) async {
    // Read from storage, not the controller: the controller loads asynchronously and may still hold its default.
    final prefs = await _ref.read(preferencesProvider.future);
    final showText = prefs.getBool(desktopMessageTextKey) ?? true;
    final channel = showText && !isDm
        ? await (await _ref.read(
            storeProvider.future,
          )).channelRow(message.channelId)
        : null;
    final live = _ref.read(memberProfileOverridesProvider);
    final members = [
      for (final m in showText ? await _roster() : const <api.UserProfile>[])
        live[m.id] ?? m,
    ];
    return desktopNotificationText(
      message,
      showText: showText,
      isDm: isDm,
      channelName: channel?.name,
      mentionNames: mentionNamesFrom(AsyncData(members)),
      authorName: _authorName(members, message),
    );
  }

  void _present(
    ({String? title, String body}) text,
    String channelId, {
    required bool mentionsSelf,
  }) {
    final origin = _ref.read(accountSlotProvider)?.account?.origin;
    final payload = origin == null
        ? null
        : NotificationTarget(origin: origin, channelId: channelId).encode();
    if (isDesktopHost && !_ref.read(appFocusedProvider)) {
      unawaited(_ref.read(taskbarAttentionProvider).flash());
    }
    // The per-kind OS control only reaches a banner filed under the kind it is; see LocalAlertChannel.
    final alertChannel = mentionsSelf
        ? LocalAlertChannel.mentions
        : LocalAlertChannel.messages;
    // Fire-and-forget behind a catch: a failed notification must never break event handling.
    unawaited(
      _guarded(
        'show a notification',
        () => _ref
            .read(localNotificationsProvider)
            .show(
              text.body,
              channel: alertChannel,
              title: text.title,
              payload: payload,
              id: previewNotificationId(channelId),
            ),
      ),
    );
  }

  Future<List<api.UserProfile>> _roster() async {
    try {
      return await _ref.read(membersProvider.future);
    } catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.platform,
        'Could not read the member list; the alert keeps the names as sent',
        error,
        stack,
      );
      return const [];
    }
  }

  /// The author's name in this space, nickname first; null keeps the message's own.
  String? _authorName(List<api.UserProfile> members, api.Message message) {
    for (final member in members) {
      if (member.id == message.authorId) return member.displayName;
    }
    return null;
  }
}
