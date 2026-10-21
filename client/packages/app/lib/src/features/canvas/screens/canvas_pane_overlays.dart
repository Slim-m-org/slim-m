// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two overlays `CanvasPaneBody` floats over the drawing surface: who else
/// is here, and the call-and-canvas dock.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../modules/widgets/dock_height_reporter.dart';
import 'canvas_call_dock.dart';
import 'canvas_dock_collapse.dart';
import 'canvas_hidden_tiles.dart';
import 'canvas_follow_controls.dart';
import 'canvas_presence_roster.dart';
import 'canvas_view_relay.dart';

/// Follow and bring-everyone when a [relay] is wired, else the plain roster.
class CanvasPeerControls extends StatelessWidget {
  const CanvasPeerControls({
    super.key,
    required this.document,
    required this.participants,
    required this.cursors,
    required this.relay,
    required this.selfId,
    this.viewMode,
  });

  final CanvasDocument document;
  final List<VoiceParticipant> participants;
  final CanvasCursors? cursors;
  final CanvasViewRelay? relay;
  final String? selfId;

  /// Whether the view is personal decides whether a summon is on offer.
  final CanvasViewMode? viewMode;

  @override
  Widget build(BuildContext context) {
    final relay = this.relay;
    final cursors = this.cursors;
    if (relay == null) {
      return CanvasPresenceRoster(
        callParticipants: participants,
        cursors: cursors,
      );
    }
    if (cursors == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: viewMode ?? relay.following,
      builder: (context, _) => CanvasFollowControls(
        relay: relay,
        cursors: cursors,
        participants: participants,
        selfId: selfId,
        canBringEveryone: !(viewMode?.personal ?? false),
        onBringEveryone: () =>
            relay.summonEveryone(document.visibleBoard ?? canvasBoard),
      ),
    );
  }
}

/// The dock pinned to the bottom edge, height-reported so the surface can
/// keep its own controls clear of it.
class CanvasDockOverlay extends StatefulWidget {
  const CanvasDockOverlay({
    super.key,
    required this.call,
    required this.canvas,
    required this.tileOverrides,
    required this.compact,
  });

  final CallDockData? call;

  /// Read inside the hidden-tile listener, so a hide or show reaches the dock's restore list.
  final CanvasDockData Function() canvas;
  final CanvasPresenceTileOverrides tileOverrides;
  final bool compact;

  @override
  State<CanvasDockOverlay> createState() => _CanvasDockOverlayState();
}

class _CanvasDockOverlayState extends State<CanvasDockOverlay> {
  late HiddenTileKeys _hidden = HiddenTileKeys(widget.tileOverrides);

  @override
  void didUpdateWidget(covariant CanvasDockOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tileOverrides != widget.tileOverrides) {
      _hidden.dispose();
      _hidden = HiddenTileKeys(widget.tileOverrides);
    }
  }

  @override
  void dispose() {
    _hidden.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canvas = widget.canvas;
    return Align(
      alignment: Alignment.bottomCenter,
      // The margin lives inside the collapse region, so a pointer at the very edge still reaches it.
      child: CanvasDockCollapse(
        collapsible: canvas().fullscreen,
        builder: (context, revealed) => Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.s12,
            canvas().fullscreen ? AppSpacing.s8 : AppSpacing.s12,
            AppSpacing.s12,
            AppSpacing.s12,
          ),
          child: DockHeightReporter(
            foldedHeight: revealed ? null : canvasDockHandleHeight,
            extraHeight: canvas().fullscreen
                ? canvasDockHandleHeight + AppSpacing.s8
                : 0,
            // Nothing else here rebuilds for a tile hide or show.
            child: ListenableBuilder(
              listenable: _hidden,
              builder: (context, _) => CanvasCallDock(
                call: widget.call,
                canvas: canvas(),
                compact: widget.compact,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
