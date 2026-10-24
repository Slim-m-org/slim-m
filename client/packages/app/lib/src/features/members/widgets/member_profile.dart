// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A profile first, everything you can do about them second: a popover on pointer layouts, a bottom sheet on compact ones, from the same content.
/// A section with no content is absent; Moderation is one "Moderate..." row pushing [MemberModerateView] into the same popover, hidden without a moderation right.
/// The call section is local to this listener; anything room-visible sits inside Moderate.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/member_moderation_error.dart';
import '../providers/member_presence.dart' show membersProvider;
import '../../../providers/providers.dart';
import '../../voice/providers/voice_controller.dart';
import '../../../widgets/confirm_dialog.dart';
import 'member_actions.dart';
import 'member_moderate_view.dart';
import 'member_moderation_gates.dart';
import 'member_profile_cards.dart';
import 'member_profile_push_transition.dart';
import 'member_profile_show.dart' show memberPopoverWidth;
import '../../voice/widgets/participant_actions.dart';
import '../../voice/widgets/participant_audio_controls.dart'
    show MemberLocalAudioSection;
import '../../../widgets/run_guarded.dart';

export 'member_profile_show.dart' show showMemberProfile;

/// Matches [AppMenu]'s own inset, which the moderation view was drawn for.
const double _moderateInset = 6;

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
    this.profileOnly = false,
  });

  final api.UserProfile profile;

  /// Shows the profile and the Message row only, leaving the action rows to the quick menu.
  final bool profileOnly;

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
    final wait = until! - clock.now().millisecondsSinceEpoch;
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
    final canRemove = gates.canRemove;
    final canManageRoles = gates.canManageRoles;
    final canIssueReset = gates.canIssueReset;
    final canEject = gates.canEject;
    final actions = participantActions(
      ParticipantActionContext(
        surface: ParticipantSurface.card,
        isSelf: isSelf,
        inCallTogether: inCallTogether,
        supportsVolume: controller.supportsParticipantVolume,
        hasProfile: true,
        showModeration: gates.showModeration,
        canCall: !profile.isBot,
      ),
    );

    // Captured before onDone, whose Navigator.pop disposes this element.
    void run(Future<void> Function(ProviderContainer container) action) {
      final container = ProviderScope.containerOf(context, listen: false);
      widget.onDone();
      unawaited(action(container));
    }

    final profileRows = isSelf
        ? SelfMemberCard(
            profile: profile,
            host: host,
            onDone: widget.onDone,
            run: run,
            memberPaneScaffold: widget.memberPaneScaffold,
          )
        : OtherMemberCard(
            profile: profile,
            gates: gates,
            actions: actions,
            host: host,
            guard: guard,
            onDone: widget.onDone,
            run: run,
            onModerate: () => setState(() => _moderating = true),
            onLiftTimeout: _liftTimeout,
            localAudio: actions.contains(ParticipantAction.muteForMe)
                ? MemberLocalAudioSection(
                    identity: profile.id,
                    controller: controller,
                    showVolume: actions.contains(ParticipantAction.volume),
                  )
                : null,
            callChannelName: widget.callChannelName,
            channelId: widget.channelId,
            memberPaneScaffold: widget.memberPaneScaffold,
            profileOnly: widget.profileOnly,
          );

    final content = _moderating
        ? Padding(
            padding: const EdgeInsets.all(_moderateInset),
            child: MemberModerateView(
              profile: profile,
              host: host,
              canManageRoles: canManageRoles,
              outranked: gates.outranked,
              canOfferTimeoutChips: gates.canOfferTimeoutChips,
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
            ),
          )
        : profileRows;

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
        padding: EdgeInsets.only(
          bottom: AppSpacing.s8 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      );
    }
    return AppMenu(
      width: memberPopoverWidth,
      padding: EdgeInsets.zero,
      children: rows,
    );
  }
}
