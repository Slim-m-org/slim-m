// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The floating dock a connected call shows once the canvas is not already
/// open for its own channel: [CallControls] plus, room permitting, a one-tap
/// way into that channel's canvas.
///
/// Before this, the canvas was reachable only from the channel header - real
/// on every width (`CanvasOpenButton`'s own doc), but a participant already
/// mid-call had to look away from the stage to find it. The header stays the
/// only entry point outside a call and still carries the reachability guard
/// (`canvas_pane_test.dart`); this is the second, in-call one.
///
/// [canvasChannelId] is null wherever this particular toggle would be
/// redundant chrome rather than a new capability - a caller already inside
/// `CanvasCallDock` passes null, since that dock's own tool strip already
/// carries "Close canvas", and a DM call passes null too: `dm_call_pane.dart`'s
/// `_DmCallBar` already carries the canvas toggle at every width (unlike a
/// voice channel's header, which only wraps the call at a width that
/// `LayoutClass.showsBothPanes`), so a second one glued onto this floating
/// dock would be the same crowding the owner already complained about this
/// dock for once, not a way to reach anything a DM call could not already
/// reach.
///
/// **Never shrinks a touch target to make room.** [CallDockButton] draws
/// every control at a fixed size regardless of width, and the canvas toggle
/// is the same button. When the row - mic, maybe speaker, camera, maybe
/// switch-camera, share, leave, and the toggle - would not fit the available
/// width at that fixed size, the toggle folds into a second row of its own
/// inside the same
/// [FloatingDockCard] instead, the identical "phone stacks two rows" shape
/// `CanvasCallDock` already uses for the call-and-canvas combination. The
/// four call controls never move: they stay the row a hand reaches for
/// without looking, matching `CanvasCallDock`'s own "a call nobody can mute
/// or leave is the one failure this dock must never produce."
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/camera_switch.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../widgets/floating_dock_card.dart';
import 'canvas/canvas_pane.dart';
import 'call_leave_button.dart';
import 'canvas/canvas_dock_toggle.dart';
import 'voice_call_controls.dart';

class VoiceCallDock extends StatefulWidget {
  const VoiceCallDock({
    super.key,
    required this.controller,
    required this.voice,
    this.canvasChannelId,
    this.botControls,
  });

  final VoiceController controller;

  /// Only the flags half: this dock never renders the roster, only
  /// [CallControls] and its own canvas toggle, both of which read [voice]
  /// for mic/camera/channel state alone.
  final VoiceFlags voice;

  /// The channel the toggle opens, or null to omit the toggle entirely -
  /// see this file's own doc for the two reasons that happens.
  final String? canvasChannelId;

  /// A bot's call controls, in a row of their own above the call's own; null
  /// when no bot on the call offers any. See decision 0045.
  final Widget? botControls;

  /// Exposed so a test can find the entrance's own `SlideTransition`
  /// directly - `MaterialApp`'s default route transition mounts one of its
  /// own around every route, so a bare `find.byType` sees two.
  static const Key slideKey = Key('voice_call_dock_slide');

  @override
  State<VoiceCallDock> createState() => _VoiceCallDockState();
}

/// Slides the dock up on first mount for a call, once - not on every rebuild
/// a mute toggle or a participant change causes while the call goes on.
///
/// [VoiceState.channelId] is what identifies "a call" here: it is set once a
/// call is joined and stays fixed for that call's whole lifetime (this dock
/// only ever builds while connected, per `_InCall`'s own guard), and only
/// takes on a new value once a real new call starts. Tracking it directly,
/// rather than trusting a caller to remount this widget with a fresh key,
/// keeps the rise correct even pumped in isolation the way
/// `voice_call_dock_test.dart` does.
class _VoiceCallDockState extends State<VoiceCallDock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.base,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.entrance,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.15),
    end: Offset.zero,
  ).animate(_curve);

  String? _playedFor;

  void _playIfNewCall() {
    final channelId = widget.voice.channelId;
    if (channelId == _playedFor) return;
    _playedFor = channelId;
    if (AppMotion.isReduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playIfNewCall();
  }

  @override
  void didUpdateWidget(covariant VoiceCallDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    _playIfNewCall();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channelId = widget.canvasChannelId;
    final leave = CallLeaveButton(controller: widget.controller);
    Widget callRow({Widget? toggle}) => CallControls(
      controller: widget.controller,
      voice: widget.voice,
      extraControl: toggle,
    );
    final botRow = widget.botControls;
    final card = channelId == null
        ? FloatingDockCard(
            rows: [?botRow, callRow()],
            trailing: leave,
            hugsWidth: true,
          )
        : Consumer(
            builder: (context, ref, _) => LayoutBuilder(
              builder: (context, constraints) {
                final toggle = _CanvasToggleButton(channelId: channelId);
                final fits = _fitsOneRow(
                  context,
                  constraints.maxWidth,
                  widget.voice.cameraEnabled &&
                      canSwitchCamera(ref, widget.controller),
                  widget.controller.supportsAudioOutputSelection,
                );
                return FloatingDockCard(
                  trailing: leave,
                  hugsWidth: true,
                  rows: [
                    ?botRow,
                    if (!fits) Center(child: toggle),
                    callRow(toggle: fits ? toggle : null),
                  ],
                );
              },
            ),
          );
    return SlideTransition(
      key: VoiceCallDock.slideKey,
      position: _slide,
      child: card,
    );
  }
}

/// Whether the call row plus the canvas toggle fit one line at [width],
/// mirroring [CallDockButton]'s own fixed-size formula rather than measuring
/// real render objects - cheap, and exact, since every control here draws at
/// one of exactly two sizes and nothing here ever wraps text.
///
/// Every button sits inside an [AppFocusRing], whose own `Container` adds
/// `focusRingGap` padding plus its border's own `focusRingGap.dimensions` on
/// every edge, reserved whether or not the ring is drawn - the same
/// measured-not-assumed extra `voice_call_controls_density_test.dart`
/// already found for this same chip.
///
/// [FloatingDockCard]'s own `Container` costs an extra 2dp beyond its
/// declared padding too, for the identical reason: `Border.all()`'s default
/// 1dp width is itself `BoxDecoration.padding`, added on top rather than
/// painted over the declared padding.
bool _fitsOneRow(
  BuildContext context,
  double width,
  bool switchCameraShown,
  bool supportsAudioOutputSelection,
) {
  final touch = AppTouchTargets.of(context);
  final hitTarget = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
  final chip = AppSizes.controlMd > hitTarget ? AppSizes.controlMd : hitTarget;
  final button = chip + 2 * (focusRingGap + focusRingWidth);
  // mic, [speaker], camera, [switch camera], share, leave, and the toggle itself.
  final controlCount =
      (switchCameraShown ? 5 : 4) + (supportsAudioOutputSelection ? 1 : 0) + 1;
  final cardPadding = AppSpacing.s12 * 2 + 2;
  // The divider before leave takes the place of one gap: s4, 1dp, s4.
  const leaveDivider = 1.0;
  final needed =
      controlCount * button +
      (controlCount - 1) * AppSpacing.s8 +
      leaveDivider +
      cardPadding;
  return needed <= width;
}

/// The toggle itself: [CanvasDockToggle], lit while [channelId]'s canvas is open.
class _CanvasToggleButton extends ConsumerWidget {
  const _CanvasToggleButton({required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(canvasOpenProvider) == channelId;
    return CanvasDockToggle(
      open: open,
      onPressed: () =>
          ref.read(canvasOpenProvider.notifier).state = open ? null : channelId,
    );
  }
}
