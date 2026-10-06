// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel: joining, and the call once you are in it.
///
/// Clicking a voice channel joins it directly. There used to be a lobby
/// screen with a mic/camera pre-toggle and an explicit Join button; the
/// owner asked twice for it to be gone, so a channel arrival auto-joins
/// (`_VoiceScreenState._maybeAutoJoin`) rather than waiting on a tap. The mic
/// and camera still open however `VoiceState.microphoneEnabled` /
/// `cameraEnabled` were last left (see `voice_controller.dart`'s `leave`,
/// which now carries those two fields across the reset), so muting before
/// leaving still means the next join opens muted.
///
/// The one case that still needs an explicit decision is switching calls:
/// arriving at a different voice channel while already connected elsewhere
/// shows `VoiceSwitchPrompt` instead of silently hanging up the first call.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'package:go_router/go_router.dart';

import '../providers/bot_ui_uses.dart';
import '../providers/call_recap.dart';
import '../providers/last_text_channel.dart';
import '../providers/dm_call_ring_controller.dart';
import '../providers/member_presence.dart' show membersProvider;
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_roster.dart';
import '../routing/breakpoints.dart';
import '../routing/routes.dart';
import '../widgets/bot_call_controls.dart';
import '../widgets/call_stage_layout.dart';
import '../widgets/dock_height_reporter.dart';
import '../widgets/member_profile.dart';
import '../widgets/participant_call_menu.dart';
import 'voice_call_dock.dart';
import 'voice_join_preview.dart';
import 'voice_text_pane.dart';

/// Whether [voice] describes a live call somewhere other than [channelId]:
/// the one case an arrival still has to ask about before joining.
///
/// `voice.joining` covers the window a join has already claimed
/// [VoiceState.channelId] but has not yet moved [VoiceState.state] off
/// whatever it was before (the token round trip in
/// [VoiceController.join] carries no state transition of its own) - without
/// it, an arrival during that window read the controller as idle and
/// auto-joined a second call with no [VoiceSwitchPrompt] at all.
///
/// Takes [VoiceFlags]: the roster has nothing to say about whether another
/// channel's call is already busy.
bool _busyElsewhere(VoiceFlags voice, String channelId) =>
    voice.channelId != null &&
    voice.channelId != channelId &&
    (voice.state == VoiceSessionState.connected ||
        voice.state == VoiceSessionState.connecting ||
        voice.joining);

/// [voice]'s recap, but only when it belongs to [channelId]: `VoiceController`
/// is one instance for every channel, and CLAUDE.md already recorded this
/// exact leak shape once for an in-call error message shown in the wrong
/// channel's preview.
CallRecap? recapForChannel(VoiceFlags voice, String channelId) =>
    voice.recap?.channelId == channelId ? voice.recap : null;

class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({
    required this.channelId,
    this.isDm = false,
    this.openChat = false,
    super.key,
  });

  final String channelId;

  /// Arrived to read the channel's chat - a tapped notification for a message
  /// in it - rather than to talk: the chat opens and the call is not joined,
  /// because joining a call must be a deliberate act. Join stays one tap away
  /// on the same screen. Picking the channel from the rail arrives without
  /// this and joins directly, as it always has.
  final bool openChat;

  /// Whether this is a DM's call rather than a real voice channel's, so the
  /// rejoin screen can say "Call" instead of "Voice channel".
  final bool isDm;

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen> {
  /// The channel id an automatic join has already been requested for, so a
  /// failure - or an explicit hang-up, which leaves this same screen still
  /// mounted - does not retry itself on every rebuild. Reset only by
  /// [_arrive]: when [widget]'s own channel changes, which is what makes
  /// revisiting the same channel a fresh attempt again, and when
  /// [VoiceScreen.openChat] flips, so the rail's pick of a channel that was
  /// opened for its chat still joins.
  String? _autoJoinedFor;

  @override
  void initState() {
    super.initState();
    _arrive();
  }

  @override
  void didUpdateWidget(covariant VoiceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId ||
        oldWidget.openChat != widget.openChat) {
      _arrive();
    }
  }

  /// A fresh arrival owes an automatic join, unless the member came to read:
  /// then it counts as already attempted, and the chat opens instead.
  void _arrive() {
    _autoJoinedFor = widget.openChat ? widget.channelId : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A phone has no docked pane to remember, so an arrival starts on the call unless it came to read.
      final compact = LayoutClass.of(context) == LayoutClass.compact;
      if (widget.openChat || compact) {
        ref.read(voiceChatPaneVisibleProvider.notifier).state = widget.openChat;
      }
    });
  }

  void _maybeAutoJoin(VoiceController controller) {
    if (_autoJoinedFor == widget.channelId) return;
    _autoJoinedFor = widget.channelId;
    final channelId = widget.channelId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.join(channelId);
    });
  }

  /// The switch prompt's own confirm action: marked as attempted the same
  /// way an automatic join is, so a failure lands on the rejoin screen
  /// rather than looping back into another switch prompt.
  void _switchNow(VoiceController controller) {
    _autoJoinedFor = widget.channelId;
    controller.join(widget.channelId);
  }

  /// A DM's first ring is spent once it was declined or timed out, so a rejoin
  /// calls again unless the other person is already in the room or a ring is out.
  void _rejoin(VoiceController controller) {
    final channelId = widget.channelId;
    unawaited(controller.join(channelId));
    if (!widget.isDm) return;
    final ringing =
        ref.read(dmCallRingControllerProvider).outgoing?.channelId == channelId;
    final roster = ref.read(voiceRosterProvider(channelId)).valueOrNull;
    if (ringing || (roster != null && roster.isNotEmpty)) return;
    final ring = ref.read(dmCallRingControllerProvider.notifier);
    unawaited(ring.startOutgoingRing(channelId));
  }

  /// Owner: the rejoin screen after a hang-up is a "useless screen". On a
  /// phone a hang-up returns to the last text channel (the shell shows the
  /// recap toast, see `listenForHangUpRecap`); a dropped or failed call never sets `justLeftAt`, so it keeps
  /// the rejoin screen. Wide layouts keep the stage beside the rail.
  void _returnAfterHangUp(VoiceFlags? before, VoiceFlags now) {
    if (widget.isDm || before?.justLeftAt == now.justLeftAt) return;
    if (now.justLeftChannelId != widget.channelId || now.justLeftAt == null) {
      return;
    }
    if (LayoutClass.of(context) != LayoutClass.compact) return;
    final last = ref.read(lastTextChannelProvider);
    context.go(last == null ? Routes.channels : Routes.channel(last));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<VoiceFlags>(voiceFlagsProvider, _returnAfterHangUp);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final voice = ref.watch(voiceFlagsProvider);
    final controller = ref.read(voiceControllerProvider.notifier);
    final channelId = widget.channelId;
    final inThisChannel = voice.channelId == channelId;
    final connectedHere =
        inThisChannel && voice.state == VoiceSessionState.connected;
    final connectingHere =
        inThisChannel && voice.state == VoiceSessionState.connecting;
    // Without this, `join`'s own in-flight window (see its own comment) reads as `attemptedThis` and briefly flashes the rejoin screen.
    final joiningHere = inThisChannel && voice.joining;
    final busyElsewhere = _busyElsewhere(voice, channelId);
    // The same canvas-pane remount that connectedHere guards against also
    // wipes this memory when the user hung up *before* closing the canvas:
    // `leave()` nulls `voice.channelId`, so the remounted screen cannot read
    // connectedHere at all. `justLeftChannelId` is what survives that instead
    // - see VoiceState.rejoinGuardWindow for how long it is trusted.
    final justLeftThis =
        voice.justLeftChannelId == channelId &&
        voice.justLeftAt != null &&
        DateTime.now().difference(voice.justLeftAt!) <
            VoiceState.rejoinGuardWindow;
    // Mounting already connected is not a fresh arrival, and this screen is
    // remounted with an empty [_autoJoinedFor] every time the canvas pane
    // swaps in and back out - without this, hanging up after that round trip
    // reads as an arrival and auto-joins the call straight back. Latching
    // justLeftThis in here too means a widget that stays mounted past
    // VoiceState.rejoinGuardWindow keeps reading as already attempted,
    // rather than flipping to a fresh arrival once the window lapses under it.
    if (connectedHere || justLeftThis) _autoJoinedFor = channelId;
    final attemptedThis = _autoJoinedFor == channelId;

    // `join` never clears `channelId` on error, so an error only ever belongs here.
    final errorMessage =
        inThisChannel && voice.state == VoiceSessionState.failed
        ? voice.error
        : null;
    final canRetry = errorMessage == null || voice.retryable;

    // A rejoin in progress stays on the call stage rather than the full-screen
    // connecting spinner: the bounded auto-rejoin behind it is still trying,
    // and the grid, filmstrip and controls it already had are worth more
    // than a blank screen while that happens. See _InCall's own banner.
    final stage = voice.inCallStageFor(channelId)
        ? 'call'
        : (connectingHere || joiningHere)
        ? 'connecting'
        : busyElsewhere
        ? 'switch'
        : attemptedThis
        ? 'left'
        : 'joining';

    if (stage == 'joining') _maybeAutoJoin(controller);

    final callBody = AppFadeIn(
      // 'joining' reads as 'connecting' here, so a fresh arrival never fades through a stage nobody would see.
      key: ValueKey('voice-${stage == 'joining' ? 'connecting' : stage}'),
      child: switch (stage) {
        'call' => _InCall(channelId: channelId, isDm: widget.isDm),
        // A rejoin in progress never reaches here: it maps to 'call' above, with its own overlay instead of this full-screen spinner.
        'connecting' || 'joining' => const VoiceConnecting(),
        'switch' => VoiceSwitchPrompt(onSwitch: () => _switchNow(controller)),
        _ => VoiceRejoinScreen(
          channelId: channelId,
          isDm: widget.isDm,
          // Only a hang-up sets justLeftChannelId; an openChat arrival that never joined has no call to have left.
          wasInCall: !widget.openChat || voice.justLeftChannelId == channelId,
          errorMessage: errorMessage,
          canRetry: canRetry,
          onRetry: () => _rejoin(controller),
          recap: recapForChannel(voice, channelId),
        ),
      },
    );

    // DmCallPane's own conversation already covers text for a DM's call; only a real voice channel gets the docked/tabbed pane below.
    if (widget.isDm) {
      return Container(color: tokens.surfaceBase, child: callBody);
    }
    final width = MediaQuery.sizeOf(context).width;
    final canDock = LayoutClass.of(context).fitsThreadPane(width);
    return Container(
      color: tokens.surfaceBase,
      child: canDock
          ? VoiceCallWithChatPane(channelId: channelId, call: callBody)
          : VoiceCallWithChatTabs(channelId: channelId, call: callBody),
    );
  }
}

/// In the call: who is here, and the controls.
///
/// The controls used to trail this column as a full-width anchored strip,
/// which is exactly what made opening the canvas make them disappear
/// outright - `ConversationPane` swaps the whole pane, controls included,
/// rather than merely covering them. They float over this content instead
/// now, in the same `FloatingDockCard` a canvas's own controls use (see
/// `canvas_call_dock.dart`), so a future viewer comparing the two screens
/// sees one dock idea rather than two. What sits beneath them is
/// `CallStageLayout` (`widgets/call_stage_layout.dart`), which carries its
/// own bottom clearance so the floating card never sits on top of its
/// content.
///
/// [isDm] withholds the dock's own canvas toggle - not because a DM call has
/// no canvas to open, but because `dm_call_pane.dart`'s `_DmCallBar` already
/// carries one at every width; see `voice_call_dock.dart` for the full
/// reasoning, and `canvas_pane_test.dart` for the header affordance this is
/// in addition to, not a replacement for.
class _InCall extends ConsumerStatefulWidget {
  const _InCall({required this.channelId, required this.isDm});

  final String channelId;
  final bool isDm;

  @override
  ConsumerState<_InCall> createState() => _InCallState();
}

class _InCallState extends ConsumerState<_InCall> {
  /// The dock's real height, which bot controls and the call row make vary;
  /// null until measured.
  double? _dockHeight;

  String get channelId => widget.channelId;
  bool get isDm => widget.isDm;

  void _onDockHeight(double height) {
    if (mounted && _dockHeight != height) setState(() => _dockHeight = height);
  }

  /// Dock plus the margin [SafeArea] keeps below it.
  double? _clearance(BuildContext context) {
    final height = _dockHeight;
    if (height == null) return null;
    final inset = MediaQuery.paddingOf(context).bottom;
    return height + (inset > AppSpacing.s12 ? inset : AppSpacing.s12);
  }

  @override
  Widget build(BuildContext context) {
    final voice = ref.watch(voiceControllerProvider);
    // autoDispose: hold the roster while a call is shown, or a tile's menu and card read it unloaded.
    ref.listen(membersProvider, (_, _) {});
    final controller = ref.read(voiceControllerProvider.notifier);
    final botGroups = isDm
        ? const <BotCallGroup>[]
        : botCallGroups(
            ref.watch(channelBotUiProvider(channelId)).valueOrNull ?? const [],
            {for (final p in voice.participants) p.identity},
          );

    return Stack(
      children: [
        CallStageLayout(
          voice: voice,
          controller: controller,
          onOpenProfile: (anchor, p) => _openProfile(anchor, ref, p),
          isDm: isDm,
          dockClearance: _clearance(context) ?? defaultDockClearance,
          menuItemsBuilder: (context, participant, close) =>
              participantCallMenuItems(
                context,
                ref,
                participant: participant,
                close: close,
              ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.all(AppSpacing.s12),
            // Pure fade: VoiceCallDock owns its own per-call rise now.
            child: AppFadeIn(
              key: ValueKey('call-dock-$channelId'),
              offset: 0,
              child: DockHeightReporter(
                onHeight: _onDockHeight,
                child: VoiceCallDock(
                  controller: controller,
                  voice: VoiceFlags.from(voice),
                  canvasChannelId: isDm ? null : channelId,
                  botControls: botGroups.isEmpty
                      ? null
                      : BotCallControls(
                          channelId: channelId,
                          groups: botGroups,
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Opens a caller's profile from their tile, which is the only route to the
/// per-participant volume control that does not go via the member pane.
///
/// The roster carries an identity and a name, not a profile, so the member
/// list is where the rest comes from. Absent from it (a member past the
/// page cap) means no profile to show rather than a wrong one, so nothing
/// opens - the alternative is a popover whose moderation half is missing
/// with no way to tell that it is.
void _openProfile(
  BuildContext context,
  WidgetRef ref,
  VoiceParticipant participant,
) {
  if (participant.isLocal) return;
  final profile = ref
      .read(membersProvider)
      .valueOrNull
      ?.where((m) => m.id == participant.identity)
      .firstOrNull;
  if (profile == null) return;

  showMemberProfile(context, profile: profile);
}
