// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two layouts of a member card: [OtherMemberCard] for someone else
/// ("Message" and "Add note" up top, channel and moderation rows apart) and
/// [SelfMemberCard] for your own (header, activity, then your own verbs).
///
/// Split out of `member_profile.dart`, which keeps the presentation, the
/// moderation view and the state that outlives a card.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/blocks_controller.dart';
import '../../channels/providers/channel_by_id_provider.dart';
import '../providers/member_presence.dart';
import '../../../providers/providers.dart';
import '../providers/user_notes.dart';
import '../../../routing/routes.dart';
import 'member_actions.dart';
import 'member_moderation_gates.dart';
import 'member_notify_off_hours_item.dart';
import 'member_profile_activity.dart';
import 'member_profile_identity.dart';
import 'member_profile_links.dart';
import 'member_profile_note_field.dart';
import 'member_profile_sections.dart';
import 'module_profile_slots.dart';
import 'profile_banner.dart';
import 'member_remove_from_channel.dart';
import '../../voice/widgets/participant_actions.dart';
import '../../../widgets/run_guarded.dart';
import 'member_voice_chip.dart';
import 'status_editor_sheet.dart';

/// Runs [action] after closing the card, with a container that outlives it.
typedef CardRun =
    void Function(Future<void> Function(ProviderContainer container) action);

/// A hairline between groups, edge to edge unlike [AppMenuDivider].
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).extension<AppTokens>()!.borderSubtle,
    child: const SizedBox(height: 1, width: double.infinity),
  );
}

/// A run of menu rows, inset so their hover tint clears the card edge.
class _Section extends StatelessWidget {
  const _Section(this.children);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: AppSpacing.s4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );
}

/// Your own card: the preview of what others see, then your own verbs.
class SelfMemberCard extends ConsumerWidget {
  const SelfMemberCard({
    super.key,
    required this.profile,
    required this.host,
    required this.onDone,
    required this.run,
    this.memberPaneScaffold,
  });

  final api.UserProfile profile;
  final BuildContext host;
  final VoidCallback onDone;
  final CardRun run;
  final ScaffoldState? memberPaneScaffold;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(meProvider).valueOrNull?.statusText ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MemberProfileBanner(profile: profile),
        MemberProfileHeader(
          profile: profile,
          isSelf: true,
          inCallTogether: false,
        ),
        if (profile.about case final about? when about.isNotEmpty)
          MemberProfileAbout(about: about),
        MemberProfileActivity(userId: profile.id),
        MemberProfileLinks(userId: profile.id),
        MemberProfileRolesAndJoin(
          roles: profile.roles,
          createdAt: profile.createdAt,
        ),
        ModuleProfileSlots(profile.id),
        const _Rule(),
        _Section([
          AppMenuItem(
            label: 'Set status',
            leading: AppIcons.smile,
            onTap: () {
              onDone();
              memberPaneScaffold?.closeEndDrawer();
              unawaited(showStatusEditorSheet(host, status));
            },
          ),
          AppMenuItem(
            label: 'Profile settings',
            leading: AppIcons.settings,
            onTap: () {
              onDone();
              memberPaneScaffold?.closeEndDrawer();
              unawaited(host.push(Routes.personalSettings));
            },
          ),
        ]),
      ],
    );
  }
}

/// Someone else's card: Message and Add note first, then the channel they
/// were opened from, then moderation and the rest.
class OtherMemberCard extends ConsumerStatefulWidget {
  const OtherMemberCard({
    super.key,
    required this.profile,
    required this.gates,
    required this.actions,
    required this.host,
    required this.guard,
    required this.onDone,
    required this.run,
    required this.onModerate,
    required this.onLiftTimeout,
    required this.localAudio,
    this.callChannelName,
    this.channelId,
    this.memberPaneScaffold,
    this.profileOnly = false,
  });

  final api.UserProfile profile;

  /// Drops the volume, notify, moderate, report and block rows.
  final bool profileOnly;
  final MemberModerationGates gates;
  final List<ParticipantAction> actions;
  final BuildContext host;
  final Guard guard;
  final VoidCallback onDone;
  final CardRun run;
  final VoidCallback onModerate;
  final Future<void> Function() onLiftTimeout;

  /// The call-local mute and volume rows, present only while in a call together.
  final Widget? localAudio;
  final String? callChannelName;

  /// The channel whose roster this card opened from, for "Remove from #channel".
  final String? channelId;
  final ScaffoldState? memberPaneScaffold;

  @override
  ConsumerState<OtherMemberCard> createState() => _OtherMemberCardState();
}

class _OtherMemberCardState extends ConsumerState<OtherMemberCard> {
  bool _noteRevealed = false;

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final gates = widget.gates;
    final hasNote =
        ref.watch(userNoteProvider(profile.id)).valueOrNull?.body?.isNotEmpty ??
        false;
    final channelId = widget.channelId;
    // The off-hours allow-list is per person, not per channel, so only removal belongs in the channel's section.
    final inChannel =
        channelId != null &&
        offersRemoveFromChannel(ref, channelId, profile) &&
        ref.watch(channelByIdProvider(channelId)).valueOrNull != null;
    final canMessage = widget.actions.contains(ParticipantAction.message);
    final canCall = widget.actions.contains(ParticipantAction.call);
    final blocked = ref.watch(blocksProvider).contains(profile.id);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MemberProfileBanner(profile: profile),
        MemberProfileHeader(
          profile: profile,
          isSelf: false,
          inCallTogether: gates.inCallTogether,
          callChannelName: widget.callChannelName,
        ),
        if (profile.about case final about? when about.isNotEmpty)
          MemberProfileAbout(about: about),
        MemberProfileActivity(userId: profile.id),
        MemberProfileVoice(userId: profile.id, onOpened: widget.onDone),
        MemberProfileLinks(userId: profile.id),
        MemberProfileRolesAndJoin(
          roles: profile.roles,
          createdAt: profile.createdAt,
          inviteCode: _inviteCode(ref, profile, gates),
        ),
        if (timeoutActive(profile.timedOutUntil))
          MemberTimeoutBadge(
            until: profile.timedOutUntil!,
            onLift: gates.canTimeOut ? widget.onLiftTimeout : null,
          ),
        ModuleProfileSlots(profile.id),
        const _Rule(),
        if (canMessage || !hasNote) _messageRow(canMessage, canCall, hasNote),
        if (hasNote || _noteRevealed)
          MemberProfileNoteField(
            subjectId: profile.id,
            autofocus: _noteRevealed && !hasNote,
          ),
        if (!widget.profileOnly) ...[
          const _Rule(),
          if (widget.localAudio case final audio?) ...[audio, const _Rule()],
          _menuSection(blocked: blocked),
          if (inChannel || !blocked) ...[
            const _Rule(),
            _dangerSection(inChannel: inChannel, blocked: blocked),
          ],
        ],
      ],
    );
  }

  Widget _messageRow(bool canMessage, bool canCall, bool hasNote) {
    final profile = widget.profile;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s12),
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          if (canMessage)
            Expanded(
              child: AppButton(
                label: 'Message',
                icon: AppIcons.chat,
                variant: AppButtonVariant.primary,
                full: true,
                onPressed: () {
                  widget.memberPaneScaffold?.closeEndDrawer();
                  widget.run(
                    (container) =>
                        messageMember(widget.host, container, profile),
                  );
                },
              ),
            ),
          if (canCall)
            AppIconButton(
              icon: AppIcons.startCall,
              semanticLabel: 'Call ${profile.displayName}',
              tooltip: 'Call',
              onPressed: () {
                widget.memberPaneScaffold?.closeEndDrawer();
                widget.run(
                  (container) => callMember(widget.host, container, profile),
                );
              },
            ),
          if (!hasNote)
            AppIconButton(
              icon: AppIcons.note,
              semanticLabel: 'Add note',
              tooltip: 'Add note',
              onPressed: () => setState(() => _noteRevealed = true),
            ),
        ],
      ),
    );
  }

  Widget _menuSection({required bool blocked}) {
    final host = widget.host;
    final profile = widget.profile;
    final run = widget.run;
    return _Section([
      MemberNotifyOffHoursItem(host: host, profile: profile, run: run),
      if (widget.actions.contains(ParticipantAction.moderate))
        AppMenuItem(
          label: 'Moderate...',
          leading: AppIcons.shield,
          submenu: true,
          onTap: widget.onModerate,
        ),
      AppMenuItem(
        label: 'Report user',
        leading: AppIcons.report,
        onTap: () => run((container) => reportMember(host, container, profile)),
      ),
      // Offering Block again to a blocked member reads as the block failing.
      if (blocked)
        AppMenuItem(
          label: 'Unblock',
          leading: AppIcons.restoreAccess,
          onTap: () =>
              run((container) => unblockMember(host, container, profile)),
        ),
    ]);
  }

  Widget _dangerSection({required bool inChannel, required bool blocked}) {
    final host = widget.host;
    final profile = widget.profile;
    return _Section([
      if (inChannel)
        MemberRemoveFromChannelItem(
          channelId: widget.channelId!,
          profile: profile,
          host: host,
          guard: widget.guard,
          onDone: widget.onDone,
        ),
      if (!blocked)
        AppMenuItem(
          label: 'Block',
          leading: AppIcons.revoke,
          tone: AppMenuItemTone.danger,
          onTap: () =>
              widget.run((container) => blockMember(host, container, profile)),
        ),
    ]);
  }
}

/// A profile resolved from a message author carries no invite code, so a
/// moderator gets it from the member list, the one read the server adds it to.
String? _inviteCode(
  WidgetRef ref,
  api.UserProfile profile,
  MemberModerationGates gates,
) {
  if (profile.inviteCode case final code?) return code;
  if (!gates.canManageRoles) return null;
  final members = ref.watch(membersProvider).valueOrNull ?? const [];
  for (final member in members) {
    if (member.id == profile.id) return member.inviteCode;
  }
  return null;
}
