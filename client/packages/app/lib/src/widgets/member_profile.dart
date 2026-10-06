// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A profile first, everything you can do about them second.
///
/// Anchored popover on a pointer layout, bottom sheet on a compact one, from
/// the same content: the member pane, a message author, and the call roster
/// all open this rather than each growing its own menu. The same body is also
/// `AvatarSettingsSection`'s own live preview of "what people in this Space
/// see when they open your card" - see `settings_profile_preview.dart`.
///
/// The profile (header, about, roles, join date) composes in a fixed order
/// and a section you have no content for is *absent*, never present-and-
/// empty - a member with no about line shows no about row at all. Actions
/// follow: Message, a private note, "Moderate...", then Report/Block.
///
/// Moderation is one row, not a wall of rows: a "Moderate..." row pushes
/// [MemberModerateView] into the same popover ([_moderating]), rather than
/// stacking a second dialog. Members without any moderation right never see
/// that row at all, so their card is profile + Message + note + Report/Block.
///
/// Everything in the call section is local to this listener and never reaches
/// the room; anything room-visible sits inside Moderate instead, which is why
/// "Mute for me" is named the way it is and why a timeout chip is not next to
/// it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/blocks_controller.dart';
import '../providers/member_moderation_error.dart';
import '../providers/member_presence.dart' show membersProvider;
import '../providers/providers.dart';
import '../providers/voice_controller.dart';
import '../routing/routes.dart';
import 'confirm_dialog.dart';
import 'member_actions.dart';
import 'member_moderate_view.dart';
import 'member_moderation_gates.dart';
import 'member_notify_off_hours_item.dart';
import 'member_profile_activity.dart';
import 'member_profile_bot_commands.dart';
import 'member_profile_identity.dart';
import 'member_profile_note_field.dart';
import 'member_profile_popover.dart';
import 'member_profile_push_transition.dart';
import 'member_profile_sections.dart';
import 'member_remove_from_channel.dart';
import 'participant_audio_controls.dart' show MemberLocalAudioSection;
import 'run_guarded.dart';

/// The popover's width on a pointer layout, from the design.
const double _popoverWidth = 300;

/// Opens the profile surface for [profile], anchored to [anchor] where there
/// is a pointer and presented as a sheet where there is not.
///
/// [anchor] is the widget the popover hangs off; the caller passes its own
/// context so the popover lands beside the row that was clicked rather than
/// in the middle of the window.
///
/// On compact width the roster this popover can open from lives in a
/// `Scaffold.endDrawer`, whose open state lives on the `ScaffoldState` and
/// outlives a `go_router` navigation - the shell's `Scaffold` is reused
/// rather than rebuilt. [Scaffold.maybeOf] is read from [anchor] here, before
/// anything else runs, so a navigating action can close it as part of
/// itself; see [MemberProfileBody.memberPaneScaffold].
Future<void> showMemberProfile(
  BuildContext anchor, {
  required api.UserProfile profile,
  String? callChannelName,
  bool initiallyModerating = false,
  String? channelId,
}) {
  // Read before anything pops: a popped context has no navigator above it.
  final host = Navigator.of(anchor, rootNavigator: true).context;
  final compact = MediaQuery.sizeOf(anchor).width < kCompactWidth;
  final memberPaneScaffold = Scaffold.maybeOf(anchor);

  if (compact) {
    // Its own controller reads the platform's own reduce-motion feature, never this app's MotionOverride; see sheet.dart's library doc.
    final noAnimation = AppMotion.isReduced(anchor)
        ? AnimationStyle.noAnimation
        : null;
    return showModalBottomSheet<void>(
      context: anchor,
      isScrollControlled: true,
      showDragHandle: true,
      sheetAnimationStyle: noAnimation,
      builder: (context) => SafeArea(
        top: false,
        child: MemberProfileBody(
          profile: profile,
          callChannelName: callChannelName,
          compact: true,
          host: host,
          memberPaneScaffold: memberPaneScaffold,
          initiallyModerating: initiallyModerating,
          channelId: channelId,
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  final box = anchor.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
  final origin = box == null || overlay == null
      ? Offset.zero
      : box.localToGlobal(Offset.zero, ancestor: overlay);
  final anchorSize = box?.size ?? Size.zero;

  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: AppMotion.reduced(anchor, AppMotion.base),
    pageBuilder: (context, _, __) => AnchoredMemberPopover(
      origin: origin,
      anchorSize: anchorSize,
      child: MemberProfileBody(
        profile: profile,
        callChannelName: callChannelName,
        compact: false,
        host: host,
        memberPaneScaffold: memberPaneScaffold,
        initiallyModerating: initiallyModerating,
        channelId: channelId,
        onDone: () => Navigator.of(context).pop(),
      ),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.entrance,
        reverseCurve: AppMotion.exit,
      );
      return FadeTransition(
        opacity: curved,
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, (1 - curved.value) * 8),
            child: child,
          ),
          child: child,
        ),
      );
    },
  );
}

/// The sections themselves, shared by both presentations.
class MemberProfileBody extends ConsumerStatefulWidget {
  const MemberProfileBody({
    super.key,
    required this.profile,
    required this.compact,
    required this.onDone,
    this.callChannelName,
    this.host,
    this.memberPaneScaffold,
    this.initiallyModerating = false,
    this.channelId,
  });

  final api.UserProfile profile;

  /// Opens straight onto [MemberModerateView] rather than the profile - a
  /// quick-actions menu's own "Moderate..." row uses this so tapping it does
  /// not land on a profile the caller already knows, one screen before the
  /// moderation the row promised.
  final bool initiallyModerating;

  /// The channel whose roster this card opened from, for "Remove from #channel".
  final String? channelId;

  /// The voice channel shared with this member, so the header can say "in
  /// lounge with you" instead of restating a presence everyone can see.
  final String? callChannelName;

  final bool compact;
  final VoidCallback onDone;

  /// A context that outlives this surface, for anything that opens a second
  /// one after this closes. Without it a follow-up sheet looks a navigator up
  /// through a context whose route has already popped, which throws.
  final BuildContext? host;

  /// The compact roster's endDrawer, if this popover opened from it. Closing
  /// it is safe to call unconditionally: [ScaffoldState.closeEndDrawer] is a
  /// no-op with nothing open, and null means there was never a drawer here.
  final ScaffoldState? memberPaneScaffold;

  @override
  ConsumerState<MemberProfileBody> createState() => _MemberProfileBodyState();
}

class _MemberProfileBodyState extends ConsumerState<MemberProfileBody>
    with GuardedActionState<MemberProfileBody> {
  /// Which half of the card is showing. Local UI state, not provider state:
  /// nothing outside this popover cares which view it is on, and it must
  /// reset to the profile every time the popover reopens fresh.
  late bool _moderating = widget.initiallyModerating;

  Timer? _expiry;
  int? _expiryFor;

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  // Repaints once at the deadline so the badge and chips follow the clock, not only a refetch.
  void _watchExpiry(int? until) {
    if (until == _expiryFor) return;
    _expiry?.cancel();
    _expiryFor = until;
    if (!timeoutActive(until)) return;
    final wait = until! - DateTime.now().millisecondsSinceEpoch;
    _expiry = Timer(Duration(milliseconds: wait + 1), () {
      if (mounted) setState(() {});
    });
  }

  api.UserProfile get _profile {
    // Live, so a timeout applied here repaints as the badge without reopening.
    final live = ref
        .watch(membersProvider)
        .valueOrNull
        ?.where((m) => m.id == widget.profile.id)
        .firstOrNull;
    return live ?? widget.profile;
  }

  Future<void> _timeOut(Duration duration) async {
    final ok = await guard(
      whatFailed: 'time this member out',
      action: () => ref
          .read(apiProvider)
          .timeOutMember(userId: widget.profile.id, duration: duration),
    );
    if (ok && mounted) ref.invalidate(membersProvider);
  }

  Future<void> _liftTimeout() async {
    final ok = await guard(
      whatFailed: 'lift the timeout',
      action: () => ref.read(apiProvider).liftMemberTimeout(widget.profile.id),
    );
    if (ok && mounted) ref.invalidate(membersProvider);
  }

  /// [channelId] is the call this member shares with the caller right now,
  /// captured before the popover is dismissed for the same reason
  /// [removeMemberFromSpace] captures its container: a kick from a room nobody is in means nothing.
  Future<void> _eject(
    BuildContext host,
    ProviderContainer container,
    String channelId,
  ) async {
    final name = widget.profile.displayName;
    final confirmed = await confirmDangerousAction(
      host,
      title: 'Eject $name from this call?',
      // A live token still works after this: says so, not just "removed".
      message:
          'They will be disconnected from the call right now. Nothing stops '
          'them rejoining - time them out or remove them from the Space for '
          'something that sticks.',
      confirmLabel: 'Eject',
    );
    if (!confirmed) return;
    container.read(memberModerationErrorProvider.notifier).state = null;
    final failure = await runGuarded(
      whatFailed: 'eject $name from the call',
      action: () => container
          .read(apiProvider)
          .kickVoiceParticipant(channelId, widget.profile.id),
    );
    if (failure != null) {
      container.read(memberModerationErrorProvider.notifier).state = failure;
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    _watchExpiry(profile.timedOutUntil);
    final controller = ref.read(voiceControllerProvider.notifier);
    final host = widget.host ?? context;

    final gates = memberModerationGates(ref, profile: profile);
    final isSelf = gates.isSelf;
    final inCallTogether = gates.inCallTogether;
    final voiceChannelId = gates.voiceChannelId;
    final canTimeOut = gates.canTimeOut;
    final canRemove = gates.canRemove;
    final canManageRoles = gates.canManageRoles;
    final canIssueReset = gates.canIssueReset;
    final canEject = gates.canEject;
    final canOfferTimeoutChips = gates.canOfferTimeoutChips;
    final showModeration = gates.showModeration;

    // Captured before onDone, whose Navigator.pop disposes this element.
    void run(Future<void> Function(ProviderContainer container) action) {
      final container = ProviderScope.containerOf(context, listen: false);
      widget.onDone();
      unawaited(action(container));
    }

    final profileRows = <Widget>[
      MemberProfileHeader(
        profile: profile,
        isSelf: isSelf,
        inCallTogether: inCallTogether,
        callChannelName: widget.callChannelName,
      ),
      if (profile.about case final about? when about.isNotEmpty)
        MemberProfileAbout(about: about),
      MemberProfileActivity(userId: profile.id),
      MemberProfileRolesAndJoin(
        roles: profile.roles,
        createdAt: profile.createdAt,
      ),

      if (timeoutActive(profile.timedOutUntil))
        MemberTimeoutBadge(
          until: profile.timedOutUntil!,
          onLift: canTimeOut ? _liftTimeout : null,
        ),

      if (profile.isBot) MemberProfileBotCommands(botId: profile.id),

      const AppMenuDivider(),

      if (inCallTogether) ...[
        MemberLocalAudioSection(identity: profile.id, controller: controller),
        const AppMenuDivider(),
      ],

      if (isSelf) ...[
        AppMenuItem(
          label: 'Profile settings',
          leading: AppIcons.settings,
          onTap: () {
            widget.onDone();
            widget.memberPaneScaffold?.closeEndDrawer();
            host.push(Routes.personalSettings);
          },
        ),
      ] else ...[
        AppMenuItem(
          label: 'Message',
          leading: AppIcons.send,
          onTap: () {
            widget.memberPaneScaffold?.closeEndDrawer();
            run((container) => messageMember(host, container, profile));
          },
        ),
        MemberProfileNoteField(subjectId: profile.id),
        MemberNotifyOffHoursItem(host: host, profile: profile, run: run),
        if (widget.channelId case final channelId?)
          MemberRemoveFromChannelItem(
            channelId: channelId,
            profile: profile,
            host: host,
            guard: guard,
            onDone: widget.onDone,
          ),
        if (showModeration) ...[
          const AppMenuDivider(),
          AppMenuItem(
            label: 'Moderate...',
            leading: AppIcons.shield,
            submenu: true,
            onTap: () => setState(() => _moderating = true),
          ),
        ],
        const AppMenuDivider(),
        AppMenuItem(
          label: 'Report user',
          leading: AppIcons.report,
          onTap: () =>
              run((container) => reportMember(host, container, profile)),
        ),
        // Offering Block again to a blocked member reads as the block failing.
        if (ref.watch(blocksProvider).contains(profile.id))
          AppMenuItem(
            label: 'Unblock',
            leading: AppIcons.restoreAccess,
            onTap: () =>
                run((container) => unblockMember(host, container, profile)),
          )
        else
          AppMenuItem(
            label: 'Block',
            leading: AppIcons.revoke,
            tone: AppMenuItemTone.danger,
            onTap: () =>
                run((container) => blockMember(host, container, profile)),
          ),
      ],
    ];

    final content = _moderating
        ? MemberModerateView(
            profile: profile,
            host: host,
            canManageRoles: canManageRoles,
            outranked: gates.outranked,
            canOfferTimeoutChips: canOfferTimeoutChips,
            canRename: gates.canRename,
            canIssueReset: canIssueReset,
            canRemove: canRemove,
            canEject: canEject,
            compact: widget.compact,
            onBack: () => setState(() => _moderating = false),
            onTimeOut: _timeOut,
            onEject: () {
              final container = ProviderScope.containerOf(
                context,
                listen: false,
              );
              final channelId = voiceChannelId;
              widget.onDone();
              unawaited(_eject(host, container, channelId!));
            },
            onRemove: () {
              final container = ProviderScope.containerOf(
                context,
                listen: false,
              );
              widget.onDone();
              unawaited(removeMemberFromSpace(host, container, profile));
            },
            onDone: widget.onDone,
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: profileRows,
          );

    final rows = <Widget>[
      MemberProfilePushTransition(
        stateKey: _moderating,
        onEscape: () {
          if (_moderating) {
            setState(() => _moderating = false);
          } else {
            widget.onDone();
          }
        },
        child: content,
      ),
      // Below the pushed view, not inside it: a Moderate refusal must show without switching views.
      if (actionError != null)
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s8),
          child: AppErrorState(
            message: actionError!,
            onDismiss: clearActionError,
          ),
        ),
    ];

    if (widget.compact) {
      // One scroll view for the whole sheet; the inset keeps a field above the keyboard.
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.s8,
          0,
          AppSpacing.s8,
          AppSpacing.s8 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      );
    }
    return AppMenu(width: _popoverWidth, children: rows);
  }
}
