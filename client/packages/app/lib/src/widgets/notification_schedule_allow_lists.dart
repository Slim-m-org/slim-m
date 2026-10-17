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

import '../features/members/providers/member_presence.dart'
    show membersProvider;
import '../providers/notification_schedule_controller.dart';
import '../providers/providers.dart';
import '../screens/admin/overwrite_target_picker_sheets.dart';
import 'run_guarded.dart';
import 'settings_hairline.dart';
import 'settings_section_header.dart';
import '../features/members/widgets/user_avatar.dart';

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

    return SettingsRowGroup(
      children: [
        const _ListLabel('PEOPLE'),
        for (final id in widget.allowedUserIds)
          AppListRow(
            leading: UserAvatar.known(
              name: byId[id]?.displayName ?? 'Former member',
              userId: id,
              avatarUpdatedAt: byId[id]?.avatarUpdatedAt,
              size: AppAvatarSize.s28,
            ),
            label: byId[id]?.displayName ?? 'Former member',
            trailing: AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Remove ${byId[id]?.displayName ?? 'member'}',
              onPressed: () => _remove(id),
            ),
          ),
        _AddRow(label: 'Add a person', onTap: _add),
        if (actionError != null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
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
  late final Stream<List<Channel>> _channels = _channelsStream();

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
    return StreamBuilder<List<Channel>>(
      stream: _channels,
      builder: (context, snapshot) {
        final byId = {
          for (final c in snapshot.data ?? const <Channel>[]) c.id: c,
        };
        return SettingsRowGroup(
          children: [
            const _ListLabel('CHANNELS'),
            for (final id in widget.allowedChannelIds)
              AppListRow(
                leading: Icon(
                  byId[id]?.kind == 'voice' ? AppIcons.voice : AppIcons.hash,
                ),
                label: byId[id]?.name ?? 'Former channel',
                trailing: AppIconButton(
                  icon: AppIcons.dismiss,
                  semanticLabel: 'Remove ${byId[id]?.name ?? 'channel'}',
                  onPressed: () => _remove(id),
                ),
              ),
            _AddRow(label: 'Add a channel', onTap: _add),
            if (actionError != null)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: AppErrorState(
                  message: actionError!,
                  onDismiss: clearActionError,
                ),
              ),
          ],
        );
      },
    );
  }

  Stream<List<Channel>> _channelsStream() async* {
    final store = await ref.read(storeProvider.future);
    yield* store.watchChannels();
  }
}

/// The mono caps label that opens each list in the always-let-through card.
class _ListLabel extends StatelessWidget {
  const _ListLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s12,
        AppSpacing.s16,
        AppSpacing.s8,
      ),
      child: Text(
        text,
        style: AppText.micro.copyWith(
          fontFamily: AppFonts.mono,
          letterSpacing: 1,
          color: tokens.textSecondary,
        ),
      ),
    );
  }
}

class _AddRow extends StatelessWidget {
  const _AddRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
            child: Text(
              '+ $label',
              style: AppText.caption.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Always let through": who and what may notify outside the schedule's hours.
class NotificationAlwaysLetThroughSection extends ConsumerWidget {
  const NotificationAlwaysLetThroughSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = ref.watch(notificationScheduleProvider).valueOrNull;
    if (schedule == null) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: 'Always let through',
      description: 'These reach you outside your hours too.',
      children: [
        NotificationScheduleAllowedPeople(
          allowedUserIds: schedule.allowedUserIds,
        ),
        NotificationScheduleAllowedChannels(
          allowedChannelIds: schedule.allowedChannelIds,
        ),
      ],
    );
  }
}
