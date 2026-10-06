// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notification schedule's two off-hours allow-lists (people and
/// channels), each an inline expander rather than a second sheet stacked on
/// top of `notification_schedule_section.dart`'s own - the desktop-vs-mobile
/// guide's rule against nested modals.
///
/// Split out of `notification_schedule_section.dart` purely to stay under
/// this repo's line budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';

import '../providers/member_presence.dart' show membersProvider;
import '../providers/notification_schedule_controller.dart';
import '../providers/providers.dart';
import '../screens/admin/overwrite_target_picker_sheets.dart';
import 'run_guarded.dart';

/// "Always notify me about" - People: the member card's own shortcut
/// (`member_card_notification_schedule_action.dart`) writes to the same
/// list this reads, so an addition made there shows up here the next time
/// this section is opened.
class NotificationScheduleAllowedPeople extends ConsumerStatefulWidget {
  const NotificationScheduleAllowedPeople({
    super.key,
    required this.allowedUserIds,
  });

  final List<String> allowedUserIds;

  @override
  ConsumerState<NotificationScheduleAllowedPeople> createState() =>
      _NotificationScheduleAllowedPeopleState();
}

class _NotificationScheduleAllowedPeopleState
    extends ConsumerState<NotificationScheduleAllowedPeople>
    with GuardedActionState<NotificationScheduleAllowedPeople> {
  bool _expanded = false;

  Future<void> _add() async {
    final member = await showAppSheet<api.UserProfile>(
      context,
      builder: (context) => const MemberPickerSheet(),
    );
    if (member == null) return;
    final ok = await guard(
      whatFailed: 'add that person to your off-hours list',
      action: () =>
          ref.read(apiProvider).addNotificationScheduleAllowedUser(member.id),
    );
    if (ok) ref.invalidate(notificationScheduleProvider);
  }

  Future<void> _remove(String userId) async {
    final ok = await guard(
      whatFailed: 'remove that person from your off-hours list',
      action: () =>
          ref.read(apiProvider).removeNotificationScheduleAllowedUser(userId),
    );
    if (ok) ref.invalidate(notificationScheduleProvider);
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(membersProvider).valueOrNull ?? const [];
    final byId = {for (final m in members) m.id: m};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppListRow(
          leading: const Icon(AppIcons.account),
          label: 'People',
          meta: '${widget.allowedUserIds.length}',
          trailing: AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: AppMotion.fast,
            child: const Icon(AppIcons.chevronDown),
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded) ...[
          for (final id in widget.allowedUserIds)
            AppListRow(
              label: byId[id]?.displayName ?? 'Former member',
              meta: byId[id] == null ? null : '@${byId[id]!.username}',
              trailing: AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Remove',
                onPressed: () => _remove(id),
              ),
            ),
          AppListRow(
            leading: const Icon(AppIcons.add),
            label: 'Add a person',
            onTap: _add,
          ),
        ],
        if (actionError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s8,
            ),
            child: AppErrorState(
              message: actionError!,
              onDismiss: clearActionError,
            ),
          ),
      ],
    );
  }
}

/// "Always notify me about" - Channels.
class NotificationScheduleAllowedChannels extends ConsumerStatefulWidget {
  const NotificationScheduleAllowedChannels({
    super.key,
    required this.allowedChannelIds,
  });

  final List<String> allowedChannelIds;

  @override
  ConsumerState<NotificationScheduleAllowedChannels> createState() =>
      _NotificationScheduleAllowedChannelsState();
}

class _NotificationScheduleAllowedChannelsState
    extends ConsumerState<NotificationScheduleAllowedChannels>
    with GuardedActionState<NotificationScheduleAllowedChannels> {
  bool _expanded = false;

  /// Built once per expand, not on every `build()`: a `StreamBuilder` given a
  /// fresh `Stream` each build re-subscribes every time, and a drift stream
  /// emits its current value immediately on listen, which turns that into a
  /// rebuild loop. It is single-subscription, so collapsing drops it and the
  /// next expand builds a new one. A collapsed row never needs a channel name
  /// at all, only the count already in
  /// [NotificationScheduleAllowedChannels.allowedChannelIds].
  Stream<List<Channel>>? _channels;

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
      _channels = _expanded ? _channelsStream() : null;
    });
  }

  Future<void> _add() async {
    final store = await ref.read(storeProvider.future);
    final channels = await store.watchChannels().first;
    if (!mounted) return;
    final picked = await showAppSheet<Channel>(
      context,
      builder: (context) => ChannelPickerSheet(channels: channels),
    );
    if (picked == null) return;
    final ok = await guard(
      whatFailed: 'add that channel to your off-hours list',
      action: () => ref
          .read(apiProvider)
          .addNotificationScheduleAllowedChannel(picked.id),
    );
    if (ok) ref.invalidate(notificationScheduleProvider);
  }

  Future<void> _remove(String channelId) async {
    final ok = await guard(
      whatFailed: 'remove that channel from your off-hours list',
      action: () => ref
          .read(apiProvider)
          .removeNotificationScheduleAllowedChannel(channelId),
    );
    if (ok) ref.invalidate(notificationScheduleProvider);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppListRow(
          leading: const Icon(AppIcons.hash),
          label: 'Channels',
          meta: '${widget.allowedChannelIds.length}',
          trailing: AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: AppMotion.fast,
            child: const Icon(AppIcons.chevronDown),
          ),
          onTap: _toggleExpanded,
        ),
        if (_expanded)
          StreamBuilder<List<Channel>>(
            stream: _channels,
            builder: (context, snapshot) {
              final byId = {
                for (final c in snapshot.data ?? const <Channel>[]) c.id: c,
              };
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final id in widget.allowedChannelIds)
                    AppListRow(
                      leading: Icon(
                        byId[id]?.kind == 'voice'
                            ? AppIcons.voice
                            : AppIcons.hash,
                      ),
                      label: byId[id]?.name ?? 'Former channel',
                      trailing: AppIconButton(
                        icon: AppIcons.dismiss,
                        semanticLabel: 'Remove',
                        onPressed: () => _remove(id),
                      ),
                    ),
                  AppListRow(
                    leading: const Icon(AppIcons.add),
                    label: 'Add a channel',
                    onTap: _add,
                  ),
                ],
              );
            },
          ),
        if (actionError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s8,
            ),
            child: AppErrorState(
              message: actionError!,
              onDismiss: clearActionError,
            ),
          ),
      ],
    );
  }

  Stream<List<Channel>> _channelsStream() async* {
    final store = await ref.read(storeProvider.future);
    yield* store.watchChannels();
  }
}
