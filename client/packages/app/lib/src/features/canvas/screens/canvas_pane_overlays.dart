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
  });

  final CanvasDocument document;
  final List<VoiceParticipant> participants;
  final CanvasCursors? cursors;
  final CanvasViewRelay? relay;
  final String? selfId;

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
    return CanvasFollowControls(
      relay: relay,
      cursors: cursors,
      participants: participants,
      selfId: selfId,
      onBringEveryone: () =>
          relay.summonEveryone(document.visibleBoard ?? canvasBoard),
    );
  }
}

/// The dock pinned to the bottom edge, height-reported so the surface can
/// keep its own controls clear of it.
class CanvasDockOverlay extends StatelessWidget {
  const CanvasDockOverlay({
    super.key,
    required this.call,
    required this.canvas,
    required this.tileOverrides,
    required this.compact,
  });

  final CallDockData? call;
  final CanvasDockData canvas;
  final CanvasPresenceTileOverrides tileOverrides;
  final bool compact;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    // The margin lives inside the collapse region, so a pointer at the very edge still reaches it.
    child: CanvasDockCollapse(
      collapsible: canvas.fullscreen,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.s12,
          canvas.fullscreen ? AppSpacing.s8 : AppSpacing.s12,
          AppSpacing.s12,
          AppSpacing.s12,
        ),
        child: DockHeightReporter(
          // The dock's hidden-tiles list must notice a hide or show landing in tileOverrides, which nothing else here rebuilds for.
          child: ListenableBuilder(
            listenable: tileOverrides,
            builder: (context, _) =>
                CanvasCallDock(call: call, canvas: canvas, compact: compact),
          ),
        ),
      ),
    ),
  );
}
