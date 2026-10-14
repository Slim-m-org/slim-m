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

import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../widgets/floating_dock_card.dart';
import 'canvas/canvas_pane.dart';
import 'call_leave_button.dart';
import 'canvas/canvas_dock_toggle.dart';
import 'dock_solo_controls.dart';

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
    final botRow = widget.botControls;
    final card = Consumer(
      builder: (context, ref, _) => LayoutBuilder(
        builder: (context, constraints) => FloatingDockCard(
          trailing: leave,
          hugsWidth: true,
          rows: [
            ?botRow,
            ...callRowsWithExtras(
              context,
              ref,
              width: constraints.maxWidth,
              controller: widget.controller,
              voice: widget.voice,
              toggle: channelId == null
                  ? null
                  : _CanvasToggleButton(channelId: channelId),
            ),
          ],
        ),
      ),
    );
    return SlideTransition(
      key: VoiceCallDock.slideKey,
      position: _slide,
      child: card,
    );
  }
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
