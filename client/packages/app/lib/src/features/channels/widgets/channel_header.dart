// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The centre column's channel header: name, topic, pin pill, and the two
/// toggles that live beside it.
///
/// The name carries this pane's identity and the topic is secondary, so the
/// name wins when the two compete for space - but only then. Weighted flex
/// expressed that as 2:1 and got the sharing wrong: a `Flexible` that asks
/// for less than its share leaves the rest unused rather than passing it on,
/// so a short name like `#general` handed the topic a third of the header and
/// ellipsised it with most of the row still empty. Measured at an 800px
/// header, the topic was capped at 250px with 467px of dead air beside it.
///
/// So the name is sized to its content under a cap and the topic takes
/// everything left, which is the same priority without the dead space.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../canvas/widgets/canvas_open_button.dart';
import '../../voice/widgets/dm_call_button.dart';
import '../../../routing/breakpoints.dart';
import 'channel_title_glyph.dart';
import 'group_dm_members_action.dart';
import 'channel_topic_text.dart';
import '../../members/widgets/member_list_toggle.dart';
import '../../messages/widgets/pinned_messages_sheet.dart';
import '../../messages/widgets/threads_sheet.dart';

/// How much of the header a channel name may take before it has to elide, so
/// a long one cannot crowd the topic out entirely. Only applies when there is
/// a topic to protect; without one the name gets the whole row.
const double _nameMaxShare = 0.6;

class ChannelHeader extends ConsumerWidget {
  const ChannelHeader({
    super.key,
    required this.channelId,
    required this.name,
    required this.isVoice,
    this.isDm = false,
    this.dmParticipantId,
    this.groupMemberIds = const [],
    this.isPersonalSpace = false,
    this.topic,
    this.restricted = false,
    required this.searchOpen,
    required this.onToggleSearch,
    this.textChatOpen = false,
    this.onToggleTextChat,
  });

  final String channelId;
  final String name;

  /// The DM peer's user id, so the header avatar's tint keys off identity
  /// the way every member-naming surface does; see [AppAvatar.tintKey].
  final String? dmParticipantId;

  /// Every participant of a group DM, the caller included; empty otherwise.
  final List<String> groupMemberIds;
  final bool isVoice;

  /// The self-DM. Its name is "Notes" (`personalSpaceName`), so it takes the
  /// same notebook glyph the rail's `PersonalSpaceRow` shows rather than an
  /// avatar of those initials. Defaults false; a real DM sets [isDm] instead.
  final bool isPersonalSpace;

  /// A DM has exactly two participants by construction, never the
  /// deployment's roster `membersProvider` answers with, so the toggle for
  /// it hides here rather than opening a pane that implies random Space
  /// members can see a private conversation. Defaults false so every
  /// existing caller (none of them a DM) keeps its toggle.
  final bool isDm;

  /// Null for no topic; the server never stores a blank one.
  final String? topic;

  /// Whether `@everyone` lacks VIEW_CHANNEL here, mirroring the wire
  /// model's own `restricted` field. False (the default) both for an
  /// ordinary channel and for a server too old to say either way, so this
  /// never claims a channel is private that it cannot vouch for. Never true
  /// alongside [isDm] or [isPersonalSpace]: neither carries `@everyone`
  /// overwrites, so the icon they already show wins.
  final bool restricted;
  final bool searchOpen;

  /// The voice shell's toggle for `voice_text_pane.dart`'s docked chat, so a
  /// voice channel has one header rather than a slim bar stacked above this
  /// one. Null renders no toggle: a text channel, or a width the pane cannot
  /// dock at - `VoiceScreen`'s own condition - so it is never dead chrome.
  final bool textChatOpen;
  final VoidCallback? onToggleTextChat;
  final VoidCallback onToggleSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // The pane only docks where LayoutClass.fitsMemberPane says there is
    // room; a toggle shown past that would sit lit over a pane that never appears.
    final canToggleMembers = !isDm && MemberListToggle.fits(context);
    // Medium widths too narrow to dock the pane open the roster as a drawer.
    final scaffold = Scaffold.maybeOf(context);
    final opensMemberDrawer =
        !isDm &&
        !canToggleMembers &&
        LayoutClass.of(context) == LayoutClass.medium &&
        scaffold != null &&
        scaffold.hasEndDrawer;

    final topic = this.topic;
    final hasTopic = topic != null && topic.isNotEmpty;

    return Container(
      height: AppSizes.headerBar,
      // Matches the message rows and composer below it.
      padding: const EdgeInsets.symmetric(horizontal: AppSizes.paneGutter),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Row(
        children: [
          // One Expanded around the whole title block, not a Flexible name
          // beside a Spacer: two flex children split the free space evenly,
          // which left the actions mid-pane with dead air to their right.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The design's 17px header left the scale
                // (app_typography.dart): it differed from body only in
                // weight, so weight alone carries it.
                final nameText = Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.medium,
                  ),
                );
                return Row(
                  children: [
                    ChannelTitleGlyph(
                      name: name,
                      isVoice: isVoice,
                      restricted: restricted,
                      isDm: isDm,
                      isPersonalSpace: isPersonalSpace,
                      dmParticipantId: dmParticipantId,
                      groupMemberIds: groupMemberIds,
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    if (!hasTopic)
                      Expanded(child: nameText)
                    else ...[
                      // Not flexible; see the library comment above.
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth * _nameMaxShare,
                        ),
                        child: nameText,
                      ),
                      const SizedBox(width: AppSpacing.s12),
                      Container(
                        width: 1,
                        height: 20,
                        color: tokens.borderSubtle,
                      ),
                      const SizedBox(width: AppSpacing.s12),
                      Expanded(child: ChannelTopicText(topic: topic)),
                    ],
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: AppSpacing.s12),
          AppIconButton(
            icon: AppIcons.pin,
            semanticLabel: 'Pinned messages',
            onPressed: () => showPinnedMessagesSheet(context, channelId),
          ),
          const SizedBox(width: AppSpacing.s4),
          if (!isVoice)
            AppIconButton(
              icon: AppIcons.thread,
              semanticLabel: 'Threads',
              onPressed: () => showThreadsSheet(context, channelId),
            ),
          const SizedBox(width: AppSpacing.s4),
          if (groupMemberIds.isNotEmpty) ...[
            GroupDmMembersAction(channelId: channelId),
            const SizedBox(width: AppSpacing.s4),
          ],
          DmCallButton(channelId: channelId),
          const SizedBox(width: AppSpacing.s4),
          if (onToggleTextChat case final toggle?) ...[
            AppIconButton(
              icon: AppIcons.chat,
              semanticLabel: 'Toggle text chat',
              active: textChatOpen,
              onPressed: toggle,
            ),
            const SizedBox(width: AppSpacing.s4),
          ],
          CanvasOpenButton(channelId: channelId, isVoice: isVoice, isDm: isDm),
          const SizedBox(width: AppSpacing.s4),
          AppIconButton(
            icon: AppIcons.search,
            semanticLabel: 'Search messages',
            active: searchOpen,
            onPressed: onToggleSearch,
          ),
          if (opensMemberDrawer) ...[
            const SizedBox(width: AppSpacing.s4),
            AppIconButton(
              icon: AppIcons.members,
              semanticLabel: 'Show members',
              onPressed: scaffold.openEndDrawer,
            ),
          ],
          if (canToggleMembers) ...[
            const SizedBox(width: AppSpacing.s4),
            const MemberListToggle(),
          ],
        ],
      ),
    );
  }
}
