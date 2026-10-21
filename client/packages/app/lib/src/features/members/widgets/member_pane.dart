// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The right-hand member pane: the roster of who holds VIEW_CHANNEL in [AppMemberPane.channelId] (`channelMembersProvider`), a display filter only.
/// Presence comes from `presenceSeedProvider` and live `presence.changed`; a first role becomes a badge and the in-call chip is derived by `MemberVoiceChip`.
/// Never offered for a DM (`_MemberPaneSlot`, `ChannelHeader.isDm`).
/// It watches presence through `rosterEntriesProvider` (regroups on section change); each `MemberRow` watches its own dot so one change does not rebuild every row.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../providers/member_presence.dart';
import '../providers/member_selection.dart';
import '../../../providers/providers.dart';
import '../providers/roster_grouping.dart';
import 'invite_friend.dart';
import 'member_bulk_actions.dart';
import 'member_pane_rows.dart';
import 'member_selection_bar.dart';

/// Whether the member pane is shown, wherever it fits. Defaults open; the
/// channel header's members toggle flips it. [HomeShell] also gates this on
/// `LayoutClass.fitsMemberPane`, since the toggle can only hide the pane, not
/// summon room for it that is not there.
final memberPaneVisibleProvider = StateProvider<bool>((ref) => true);

/// A window shorter than this does not open the member pane by itself.
const double kMemberPaneAutoOpenMinHeight = 500;

/// Set while the viewer opened the pane by hand on a window too short to open
/// it automatically; the header toggle is the only writer.
final memberPaneOpenedByHandProvider = StateProvider<bool>((ref) => false);

/// Whether the docked pane is wanted at [size]: not hidden, and either tall
/// enough to open by default or opened by hand.
bool memberPaneWanted(WidgetRef ref, Size size) =>
    ref.watch(memberPaneVisibleProvider) &&
    (size.height >= kMemberPaneAutoOpenMinHeight ||
        ref.watch(memberPaneOpenedByHandProvider));

/// 236px, `--surface-sunken`, a left hairline: the design's right member pane.
class AppMemberPane extends ConsumerWidget {
  const AppMemberPane({super.key, required this.channelId, this.onClose});

  /// Closes a docked pane; null where it is a drawer, which closes itself.
  final VoidCallback? onClose;

  /// The channel this pane sits beside. The roster is narrowed to who can
  /// view it, so a channel an overwrite closes off does not list the people
  /// shut out of it.
  ///
  /// Null when nothing is selected, which is the one case with no channel to
  /// narrow to; the deployment roster stands in rather than an empty pane.
  final String? channelId;

  static const double width = 236;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final channelId = this.channelId;
    final membersAsync = channelId == null
        ? ref.watch(membersProvider)
        : ref.watch(channelMembersProvider(channelId));
    // Purely to start the seed fetch; statuses reach each row through presenceForProvider.
    ref.watch(presenceSeedProvider(channelId));
    // Purely a side-effect subscription: a join, a timeout or a moderation event makes a row on screen wrong.
    ref.watch(memberModerationWatcherProvider);
    final mine = ref.watch(myPermissionsProvider);
    final canTimeOut = mine.hasPermission(Perm.kickMembers);
    final canRemove = mine.hasPermission(Perm.banMembers);
    // Scoped: the selection is a new object per toggle, so watching it whole rebuilds every row.
    final selecting = ref.watch(
      memberSelectionProvider.select((s) => s.active),
    );
    // A bit revoked mid-selection leaves a mode with no verb left in it.
    ref.listen(myPermissionsProvider, (_, next) {
      final stillAllowed =
          next.hasPermission(Perm.kickMembers) ||
          next.hasPermission(Perm.banMembers);
      if (!stillAllowed) ref.read(memberSelectionProvider.notifier).clear();
    });

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border(left: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Column(
        children: [
          _Header(
            count: membersAsync.valueOrNull?.length,
            onClose: onClose,
            onInvite: watchCanInviteFriend(ref)
                ? () => inviteAFriend(context)
                : null,
            // Only a moderator is offered the mode; the server refuses the rest anyway.
            onStartSelecting: (canTimeOut || canRemove) && !selecting
                ? ref.read(memberSelectionProvider.notifier).enter
                : null,
          ),
          Expanded(
            child: membersAsync.when(
              loading: () =>
                  const Center(child: AppSpinner(size: AppSpinnerSize.lg)),
              error: (error, _) => _MembersError(
                error: error,
                onRetry: () => channelId == null
                    ? ref.invalidate(membersProvider)
                    : ref.invalidate(channelMembersProvider(channelId)),
              ),
              data: (_) => _RosterList(channelId: channelId),
            ),
          ),
          // Outside the async branches on purpose: a roster refetch that fails
          // mid-selection must not take the only way out of the mode with it.
          if (selecting)
            MemberSelectionBar(
              canTimeOut: canTimeOut,
              canRemove: canRemove,
              onTimeOut: (duration) =>
                  unawaited(timeOutSelectedMembers(ref, duration)),
              onRemove: () => confirmAndRemoveSelectedMembers(ref, context),
            ),
        ],
      ),
    );
  }
}

class _MembersError extends StatelessWidget {
  const _MembersError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Could not load members.',
              style: TextStyle(color: tokens.textSecondary),
              textAlign: TextAlign.center,
            ),
            // A 403 means a lost permission, not a fault: retrying would only fail the same way.
            if (error is! api.ForbiddenException) ...[
              const SizedBox(height: AppSpacing.s12),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

class _RosterList extends ConsumerWidget {
  const _RosterList({required this.channelId});

  final String? channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myId = ref.watch(meProvider).valueOrNull?.id;
    final entries = ref.watch(rosterEntriesProvider(channelId));
    // Lazy, so a large roster builds only the rows on screen.
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s8,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) => switch (entries[index]) {
        RosterGroupLabel(:final text) => MemberGroupLabel(text),
        RosterMember(:final profile, :final sectionRoleId) => MemberRow(
          profile: profile,
          sectionRoleId: sectionRoleId,
          isSelf: profile.id == myId,
          channelId: channelId,
        ),
      },
    );
  }
}

/// The pane's own title bar, counting the whole roster.
///
/// Never the filtered count: this pane is where somebody checks how big the
/// Space is, and a search box quietly changing that number would answer a
/// question nobody asked.
class _Header extends StatelessWidget {
  const _Header({
    required this.count,
    this.onInvite,
    this.onStartSelecting,
    this.onClose,
  });

  final int? count;

  /// Null when the viewer may not invite.
  final VoidCallback? onInvite;
  final VoidCallback? onClose;

  /// Enters selection mode. Null when the viewer holds neither moderation
  /// bit, or when the mode is already running.
  final VoidCallback? onStartSelecting;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      height: AppSizes.headerBar,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count == null ? 'MEMBERS' : 'MEMBERS · $count',
              style: AppText.label.copyWith(color: tokens.textSecondary),
            ),
          ),
          if (onInvite != null)
            AppIconButton(
              icon: AppIcons.invite,
              semanticLabel: 'Invite a friend',
              tooltip: 'Invite a friend',
              onPressed: onInvite,
            ),
          if (onStartSelecting != null)
            AppIconButton(
              icon: AppIcons.shield,
              semanticLabel: 'Select members to moderate',
              onPressed: onStartSelecting,
            ),
          if (onClose != null)
            AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Close member list',
              tooltip: 'Close member list',
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}
