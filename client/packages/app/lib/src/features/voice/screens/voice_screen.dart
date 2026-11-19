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
/// An arrival to read or look shows the channel instead, and asks only when
/// its Join is pressed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'package:go_router/go_router.dart';

import '../providers/call_recap.dart';
import '../../channels/providers/last_text_channel.dart';
import '../providers/dm_call_ring_controller.dart';
import '../providers/voice_call_history.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_elsewhere.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_roster.dart';
import '../../../routing/breakpoints.dart';
import '../../../routing/launch_route.dart';
import '../../../routing/routes.dart';
import '../widgets/transcription_notice.dart';
import 'call_details_pane.dart';
import 'voice_in_call.dart';
import '../../canvas/screens/canvas_pane.dart' show canvasOpenProvider;
import 'voice_idle/voice_channel_idle.dart';
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
/// is one instance for every channel, and an in-call error message has
/// already leaked this exact way into the wrong channel's preview.
CallRecap? recapForChannel(VoiceFlags voice, String channelId) =>
    voice.recap?.channelId == channelId ? voice.recap : null;

class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({
    required this.channelId,
    this.isDm = false,
    this.openChat = false,
    this.openDetails = false,
    super.key,
  });

  final String channelId;

  /// Arrived to read the channel's chat - a tapped notification for a message
  /// in it - rather than to talk: the chat opens and the call is not joined,
  /// because joining a call must be a deliberate act. Join stays one tap away
  /// on the same screen. Picking the channel from the rail arrives without
  /// this and joins directly, as it always has.
  final bool openChat;

  /// Arrived to look over the channel's calls - its row menu's View details -
  /// rather than to talk: the page shows them with Join beside them, and the
  /// call is not joined. Already in this call, its details open instead.
  final bool openDetails;

  /// Whether this is a DM's call rather than a real voice channel's, so the
  /// rejoin screen can say "Call" instead of "Voice channel".
  final bool isDm;

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

/// The channel whose screen handed over to its canvas after its join was
/// already settled, so the remount when the canvas closes is not an arrival.
final _canvasHandoffProvider = StateProvider<String?>((ref) => null);

class _VoiceScreenState extends ConsumerState<VoiceScreen> {
  /// The channel id an automatic join has already been requested for, so a
  /// failure - or an explicit hang-up, which leaves this same screen still
  /// mounted - does not retry itself on every rebuild. Reset only by
  /// [_arrive]: when [widget]'s own channel changes, which is what makes
  /// revisiting the same channel a fresh attempt again, and when
  /// [VoiceScreen.openChat] or [VoiceScreen.openDetails] flips, so the rail's
  /// pick of a channel that was opened to read or look over still joins.
  String? _autoJoinedFor;

  /// The channel this account is in on another device, while its prompt waits.
  String? _elsewhere;
  VoidCallback? _confirmedJoin;
  bool _checking = false;

  /// The join a press on the page asked for while in another call, waiting on the switch prompt.
  Future<void> Function()? _switchJoin;

  /// Bumped by each pre-join check, a Cancel and an arrival, so a check that answers late knows it was dropped.
  int _check = 0;

  @override
  void initState() {
    super.initState();
    _arrive();
  }

  @override
  void didUpdateWidget(covariant VoiceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId ||
        oldWidget.openChat != widget.openChat ||
        oldWidget.openDetails != widget.openDetails) {
      _arrive();
    }
  }

  /// A fresh arrival owes an automatic join, unless the member came to read
  /// or look: then it counts as already attempted, and the chat or the
  /// channel's calls show instead.
  void _arrive() {
    // Closing the canvas remounts this screen with no memory; the handoff carries it across, however long the canvas was open.
    final handedOff = ref.read(_canvasHandoffProvider) == widget.channelId;
    // A page load onto this channel is not a click; a DM's call never opens from the address.
    final loaded =
        !widget.isDm &&
        ref.read(launchRouteProvider).takeArrival(widget.channelId);
    final looking = widget.openChat || widget.openDetails;
    _autoJoinedFor = looking || handedOff || loaded ? widget.channelId : null;
    _check++;
    _checking = false;
    _elsewhere = null;
    _confirmedJoin = null;
    _switchJoin = null;
    final channelId = widget.channelId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (handedOff) ref.read(_canvasHandoffProvider.notifier).state = null;
      // A phone has no docked pane to remember, so an arrival starts on the call unless it came to read.
      final compact = LayoutClass.of(context) == LayoutClass.compact;
      if (looking || compact) {
        ref.read(voiceChatPaneVisibleProvider.notifier).state = widget.openChat;
      }
      final inCall = ref.read(voiceFlagsProvider).inCallStageFor(channelId);
      if (widget.openDetails && inCall) _showDetails();
    });
  }

  /// Opens the call's details, docked or as a sheet, unless already docked open.
  void _showDetails() {
    if (callDetailsDocks(context) && ref.read(callDetailsOpenProvider)) return;
    toggleCallDetails(context, ref, widget.channelId);
  }

  void _maybeAutoJoin(VoiceController controller) {
    if (_autoJoinedFor == widget.channelId) return;
    _autoJoinedFor = widget.channelId;
    final channelId = widget.channelId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_joinConfirmed(() => controller.join(channelId)));
    });
  }

  /// Runs [join] now, after the one-time transcription notice, or after "Join here" when it would move a call open on another device.
  /// A call that came up meanwhile, here or elsewhere, wins over the join.
  Future<void> _joinConfirmed(Future<void> Function() join) async {
    final check = ++_check;
    final channelId = widget.channelId;
    bool dropped() => !mounted || check != _check;
    if (!widget.isDm && !await confirmTranscriptionNotice(context, ref)) return;
    if (dropped()) return;
    setState(() => _checking = true);
    final String? elsewhere;
    try {
      elsewhere = await ref.read(voiceElsewhereCheckProvider)(channelId);
    } finally {
      if (!dropped()) setState(() => _checking = false);
    }
    final voice = ref.read(voiceFlagsProvider);
    if (dropped() || voice.inCallStageFor(channelId)) return;
    if (_busyElsewhere(voice, channelId)) return;
    if (elsewhere == null) return join();
    setState(() {
      _elsewhere = elsewhere;
      _confirmedJoin = () => unawaited(join());
    });
  }

  void _joinHere() {
    final join = _confirmedJoin;
    setState(() {
      _elsewhere = null;
      _confirmedJoin = null;
    });
    join?.call();
  }

  /// Drops a pending check; only a join of this channel that is not yet up is left.
  void _cancelJoin(VoiceController controller) {
    _check++;
    _autoJoinedFor = widget.channelId;
    setState(() => _checking = false);
    final voice = ref.read(voiceFlagsProvider);
    if (voice.channelId == widget.channelId && !voice.callLive) {
      unawaited(controller.leave());
    }
  }

  void _cancelJoinHere() => setState(() {
    _elsewhere = null;
    _confirmedJoin = null;
  });

  /// The switch prompt's own confirm action: marked as attempted the same
  /// way an automatic join is, so a failure lands on the rejoin screen
  /// rather than looping back into another switch prompt.
  void _switchNow(VoiceController controller) {
    _autoJoinedFor = widget.channelId;
    final join = _switchJoin ?? () => controller.join(widget.channelId);
    _switchJoin = null;
    unawaited(join());
  }

  /// Back to the page a press on its Join came from, still in the other call.
  void _cancelSwitch() => setState(() => _switchJoin = null);

  /// The idle pane's join: muted unless [withMic], marked as attempted like a
  /// rejoin. In another call it asks first, since joining leaves that call.
  void _joinMuted(VoiceController controller, {bool withMic = false}) {
    _autoJoinedFor = widget.channelId;
    final channelId = widget.channelId;
    Future<void> join() =>
        withMic ? controller.join(channelId) : controller.joinMuted(channelId);
    if (_busyElsewhere(ref.read(voiceFlagsProvider), channelId)) {
      setState(() => _switchJoin = join);
      return;
    }
    unawaited(_joinConfirmed(join));
  }

  /// A DM's first ring is spent once it was declined or timed out, so a rejoin
  /// calls again unless the other person is already in the room or a ring is out.
  void _rejoin(VoiceController controller) {
    unawaited(_joinConfirmed(() => _rejoinNow(controller)));
  }

  Future<void> _rejoinNow(VoiceController controller) async {
    final channelId = widget.channelId;
    final joined = controller.join(channelId);
    if (widget.isDm) _ringAfterRejoin(channelId);
    await joined;
  }

  void _ringAfterRejoin(String channelId) {
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

  bool _justLeftThis(VoiceFlags voice) {
    final leftAt = voice.justLeftAt;
    return voice.justLeftChannelId == widget.channelId &&
        leftAt != null &&
        DateTime.now().difference(leftAt) < VoiceState.rejoinGuardWindow;
  }

  String _waitingStage({
    required bool connecting,
    required bool busyElsewhere,
    required bool attempted,
  }) {
    if (_elsewhere != null) return 'elsewhere';
    if (connecting || (_checking && !busyElsewhere)) return 'connecting';
    // Arriving to read or look shows the page; only a press on its Join asks to switch.
    final looking = widget.openChat || widget.openDetails;
    if (busyElsewhere && (!looking || _switchJoin != null)) return 'switch';
    return attempted ? 'left' : 'joining';
  }

  Widget _callBody(
    String stage, {
    required VoiceFlags voice,
    required VoiceController controller,
    required bool connectingHere,
    required String? errorMessage,
    required bool canRetry,
  }) {
    final channelId = widget.channelId;
    return AppFadeIn(
      // 'joining' reads as 'connecting' here, so a fresh arrival never fades through a stage nobody would see.
      key: ValueKey('voice-${stage == 'joining' ? 'connecting' : stage}'),
      child: switch (stage) {
        'call' => VoiceInCall(channelId: channelId, isDm: widget.isDm),
        // A rejoin in progress never reaches here: it maps to 'call' above, with its own overlay instead of this full-screen spinner.
        'connecting' || 'joining' => VoiceConnecting(
          channelId: channelId,
          negotiating: connectingHere,
          onCancel: () => _cancelJoin(controller),
        ),
        'elsewhere' => VoiceJoinHerePrompt(
          elsewhereChannelId: _elsewhere!,
          onJoin: _joinHere,
          onCancel: _cancelJoinHere,
        ),
        'switch' => VoiceSwitchPrompt(
          onSwitch: () => _switchNow(controller),
          onCancel: _switchJoin == null ? null : _cancelSwitch,
        ),
        _ when !widget.isDm => VoiceChannelIdle(
          channelId: channelId,
          errorMessage: errorMessage,
          canRetry: canRetry,
          recap: recapForChannel(voice, channelId),
          onJoin: () => _joinMuted(controller),
          onJoinWithMic: () => _joinMuted(controller, withMic: true),
          // Whichever join failed, a tap here or the automatic one on arrival.
          onRetry: () =>
              _joinMuted(controller, withMic: !controller.lastJoinMuted),
          onOpenCanvas: () =>
              ref.read(canvasOpenProvider.notifier).state = channelId,
        ),
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
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(canvasOpenProvider, (_, open) {
      if (open == widget.channelId && _autoJoinedFor == widget.channelId) {
        ref.read(_canvasHandoffProvider.notifier).state = widget.channelId;
      }
    });
    ref.listen<VoiceFlags>(voiceFlagsProvider, _returnAfterHangUp);
    ref.listen(voiceRejoinRequestProvider, (_, request) {
      if (request?.channelId != widget.channelId) return;
      final controller = ref.read(voiceControllerProvider.notifier);
      unawaited(_joinConfirmed(() => controller.join(widget.channelId)));
    });
    ref.listen(callDetailsRequestProvider, (_, request) {
      if (request?.channelId != widget.channelId) return;
      if (ref.read(voiceFlagsProvider).inCallStageFor(widget.channelId)) {
        _showDetails();
      }
    });
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
    final justLeftThis = _justLeftThis(voice);
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
    // than a blank screen while that happens. See VoiceInCall's own banner.
    final stage = voice.inCallStageFor(channelId)
        ? 'call'
        : _waitingStage(
            connecting: connectingHere || joiningHere,
            busyElsewhere: busyElsewhere,
            attempted: attemptedThis,
          );

    if (stage == 'joining') _maybeAutoJoin(controller);

    final callBody = _callBody(
      stage,
      voice: voice,
      controller: controller,
      connectingHere: connectingHere,
      errorMessage: errorMessage,
      canRetry: canRetry,
    );

    // DmCallPane's own conversation already covers text for a DM's call; only a real voice channel gets the docked/tabbed pane below.
    if (widget.isDm) {
      return PaneSurface(color: tokens.surfaceBase, child: callBody);
    }
    final width = MediaQuery.sizeOf(context).width;
    final canDock = LayoutClass.of(context).fitsThreadPane(width);
    return PaneSurface(
      color: tokens.surfaceBase,
      child: canDock
          ? VoiceCallWithChatPane(
              channelId: channelId,
              call: callBody,
              details: stage == 'call'
                  ? CallDetailsPanel(channelId: channelId)
                  : null,
            )
          : VoiceCallWithChatTabs(channelId: channelId, call: callBody),
    );
  }
}
