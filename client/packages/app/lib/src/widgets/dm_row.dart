// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One direct-message row in the rail: open on tap, and a right-click or
/// long-press menu to close it, mute it, narrow it to mentions only, or
/// report or block the person on the other end of it.
///
/// Also the in-app half of `docs/IMPLIED-GAPS.md` #2: a call already
/// happening in this DM shows as an icon, and tapping the row while it is
/// lit opens straight into the call pane rather than the plain transcript.
/// Kept current by `dmCallActivityProvider` (`providers/dm_call_activity.dart`)
/// rather than `voiceRosterProvider`'s own per-channel poll: every DM row
/// mounts at once (`DirectMessagesSection` renders the whole list), and one
/// independent 15-second poller per row multiplied with the DM list and
/// burst the write-class rate budget the instant the rail rendered. See that
/// provider's own doc comment for the fix.
///
/// "Close DM" is a real per-viewer hide on the server (`DELETE /dms/{userId}`,
/// `store/dms.rs`'s `dm_hides`), not a client-only flag: unlike the personal
/// space's own "Remove from list" (`personal_space_menu.dart`), which hides a
/// channel that is entirely the caller's own, a client-only hide of a shared
/// DM would silently disagree with every other device signed into the same
/// account. It reverses itself once the other person sends something new, or
/// the moment this device opens or messages them again.
///
/// The avatar carries the peer's presence dot, the same [UserAvatar] dot
/// `MemberRow` draws; `DirectMessagesSection` seeds it from the
/// deployment-wide roster, since one deployment is one community and every
/// DM peer is already a member of it. A peer not yet reported draws none.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/blocks_controller.dart';
import '../providers/channel_notification_overrides_controller.dart';
import '../providers/dm_call_activity.dart';
import '../providers/dms.dart';
import '../providers/unread_indicator_rules.dart';
import '../routing/routes.dart';
import '../screens/dm_call_pane.dart' show dmCallOpenProvider;
import 'context_menu_region.dart';
import 'row_menu_notifications.dart';
import 'safety_actions.dart';
import 'user_avatar.dart';

/// [channel] is never the caller's own personal space: that DM-shaped row is
/// [PersonalSpaceRow], reached separately, since a self-conversation has no
/// other participant to report or block.
class DmRow extends ConsumerWidget {
  const DmRow({super.key, required this.channel, required this.selected});

  final Channel channel;
  final bool selected;

  /// Read fresh every time the menu opens rather than watched: the row
  /// itself already rebuilds on a live block change, and a menu that is
  /// already open does not need to react to one landing mid-look.
  List<Widget> _menuItems(
    BuildContext context,
    WidgetRef ref,
    VoidCallback close,
  ) {
    final peerId = channel.dmParticipantId;
    final blocked = peerId != null && ref.read(blocksProvider).contains(peerId);
    final container = ProviderScope.containerOf(context, listen: false);
    void run(Future<void> Function() action) {
      close();
      unawaited(action());
    }

    return [
      AppMenuItem(
        label: 'Open',
        leading: AppIcons.send,
        onTap: () {
          close();
          context.go(Routes.channel(channel.id));
        },
      ),
      if (peerId != null)
        AppMenuItem(
          label: 'Close DM',
          leading: AppIcons.dismiss,
          onTap: () =>
              run(() => hideDmConversation(container, peerId, channel.id)),
        ),
      markUnreadMenuItem(context, container, channel.id, close),
      const AppMenuDivider(),
      ...notificationMenuItems(
        context,
        container,
        channel.id,
        close,
        muteLabel: 'Mute',
      ),
      if (peerId != null) ...[
        const AppMenuDivider(),
        AppMenuItem(
          label: 'Report user',
          leading: AppIcons.report,
          onTap: () => run(
            () => fileReport(
              context,
              container,
              subject: api.ReportSubject.user,
              subjectId: peerId,
              subjectLabel: 'this member',
            ),
          ),
        ),
        if (blocked)
          AppMenuItem(
            label: 'Unblock',
            leading: AppIcons.restoreAccess,
            onTap: () => run(() => unblockUser(context, container, peerId)),
          )
        else
          AppMenuItem(
            label: 'Block',
            leading: AppIcons.revoke,
            tone: AppMenuItemTone.danger,
            onTap: () => run(() => blockUser(context, container, peerId)),
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Queued, not fetched directly: the controller bounds how many rows become simultaneous requests.
    ref.read(dmCallActivityProvider.notifier).ensureTracked(channel.id);
    final inCall = ref.watch(
      dmCallActivityProvider.select((m) => m[channel.id] ?? false),
    );
    // A live call outranks the mute glyph in this one slot; unread still counts either way.
    final override = ref.watch(
      channelNotificationOverridesProvider.select(
        (s) => s.overrideFor(channel.id),
      ),
    );
    final muted = override == api.NotificationPreference.nothing;
    // Mentions-only leaves a DM loud: somebody writing here is addressing this account directly.
    final indicator = unreadIndicatorFor(
      channelOverride: override,
      isDm: true,
      unread: channel.cursor > channel.lastReadSeq,
      mentioned: channel.mentionedSeq > channel.lastReadSeq,
      manuallyUnread: channel.manuallyUnread ?? false,
    );
    return ContextMenuRegion(
      itemsBuilder: (menuContext, close) => _menuItems(menuContext, ref, close),
      // AppListRow is already its own tab stop; see ContextMenuFocus.ownsFocusNode.
      ownsFocusNode: false,
      child: AppListRow(
        label: channel.name,
        selected: selected,
        unread: indicator.unread,
        mentioned: indicator.mentioned,
        muted: muted,
        leading: UserAvatar(
          name: channel.name,
          userId: channel.dmParticipantId,
          size: AppAvatarSize.s28,
          presence: true,
        ),
        trailing: inCall
            ? Icon(
                AppIcons.startCall,
                size: AppSizes.icon16,
                color: tokens.accent,
              )
            : muted
            ? Icon(
                AppIcons.notificationsOff,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              )
            : null,
        stateDescription: inCall ? 'call in progress' : null,
        onTap: () {
          // Opens straight into the call pane, the same double action RailCallSummary uses.
          if (inCall) ref.read(dmCallOpenProvider.notifier).state = channel.id;
          context.go(Routes.channel(channel.id));
        },
      ),
    );
  }
}
