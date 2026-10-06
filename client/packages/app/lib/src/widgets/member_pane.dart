// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The right-hand member pane: the deployment's roster.
///
/// Presence is real now: `presenceSeedProvider` (in `member_presence.dart`,
/// where the roster and presence data this pane renders all live now)
/// batch-fetches status for the resolved member list and
/// the presence controller keeps it current from live `presence.changed`
/// events, so the roster grouping gets a real status map instead of an empty
/// one.
///
/// A member's first role becomes a badge. `@everyone` is excluded server-side,
/// so an empty list means no badge rather than no data. There is still no
/// in-voice flag on a profile, so the design's speaker glyph is left off.
///
/// The roster is `channelMembersProvider`, narrowed server-side to who holds
/// VIEW_CHANNEL in [AppMemberPane.channelId]. It used to be the whole
/// deployment, which listed people an overwrite had shut out of the channel
/// the pane was sitting beside - the pane's own heading claims to say who is
/// here, so that was wrong even though none of it was secret. The unfiltered
/// roster is still readable from the same route by any authenticated caller,
/// which is why this is a display filter and nothing more.
///
/// The pane must still never be offered for a DM, whose two participants are
/// never this list; `home_shell.dart`'s `_MemberPaneSlot` and
/// `channel_header.dart`'s `ChannelHeader.isDm` are what withhold it there.
///
/// This pane watches presence only through `rosterEntriesProvider`, which
/// regroups when someone crosses between sections and not when a dot changes
/// colour within one. Each `MemberRow` separately watches its own id for the
/// dot itself, which is what keeps a single dot change from rebuilding every
/// row.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../permissions.dart';
import '../providers/admin_providers.dart';
import '../providers/member_presence.dart';
import '../providers/member_selection.dart';
import '../providers/providers.dart';
import '../providers/roster_grouping.dart';
import 'member_bulk_actions.dart';
import 'member_pane_rows.dart';
import 'member_selection_bar.dart';

/// Whether the member pane is shown, wherever it fits. Defaults open; the
/// channel header's members toggle flips it. [HomeShell] also gates this on
/// `LayoutClass.fitsMemberPane`, since the toggle can only hide the pane, not
/// summon room for it that is not there.
final memberPaneVisibleProvider = StateProvider<bool>((ref) => true);

/// 236px, `--surface-sunken`, a left hairline: the design's right member pane.
class AppMemberPane extends ConsumerWidget {
  const AppMemberPane({super.key, required this.channelId});

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
    final myId = ref.watch(meProvider).valueOrNull?.id;
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
            // Only a moderator is offered the mode; the server refuses the rest anyway.
            onStartSelecting: (canTimeOut || canRemove) && !selecting
                ? ref.read(memberSelectionProvider.notifier).enter
                : null,
          ),
          Expanded(
            child: membersAsync.when(
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (error, _) => Center(
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
                        TextButton(
                          onPressed: () => channelId == null
                              ? ref.invalidate(membersProvider)
                              : ref.invalidate(
                                  channelMembersProvider(channelId),
                                ),
                          child: const Text('Retry'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              data: (_) {
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
                    RosterMember(:final profile, :final sectionRoleId) =>
                      MemberRow(
                        profile: profile,
                        sectionRoleId: sectionRoleId,
                        isSelf: profile.id == myId,
                        channelId: channelId,
                      ),
                  },
                );
              },
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

/// The pane's own title bar, counting the whole roster.
///
/// Never the filtered count: this pane is where somebody checks how big the
/// Space is, and a search box quietly changing that number would answer a
/// question nobody asked.
class _Header extends StatelessWidget {
  const _Header({required this.count, this.onStartSelecting});

  final int? count;

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
          if (onStartSelecting != null)
            AppIconButton(
              icon: AppIcons.shield,
              semanticLabel: 'Select members to moderate',
              onPressed: onStartSelecting,
            ),
        ],
      ),
    );
  }
}
