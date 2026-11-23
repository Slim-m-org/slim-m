// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The board surface with the notice, dock, peer controls and badges layered over it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_board_pager.dart' show CanvasPaging;
import 'canvas_call_dock.dart';
import 'canvas_notice.dart';
import 'canvas_pane_overlays.dart';
import 'canvas_paging_indicator.dart';
import 'canvas_short_toggle.dart';
import 'canvas_speaking_sync.dart';
import 'canvas_view_relay.dart';

/// Clipped so canvas content panned past the top edge never paints over the header above it.
class CanvasBoardStack extends StatelessWidget {
  const CanvasBoardStack({
    super.key,
    required this.surface,
    required this.channelId,
    required this.cursors,
    required this.callParticipants,
    required this.viewRelay,
    required this.selfId,
    required this.onAcceptSummon,
    required this.paging,
    required this.notice,
    required this.callDock,
    required this.dockData,
    required this.tileOverrides,
    required this.compact,
    required this.showShortToggle,
    required this.showPeerControls,
  });

  final Widget surface;
  final String channelId;
  final CanvasCursors? cursors;
  final List<VoiceParticipant> callParticipants;
  final CanvasViewRelay? viewRelay;
  final String? selfId;
  final VoidCallback onAcceptSummon;
  final CanvasPaging? paging;
  final CanvasNotice notice;
  final CallDockData? callDock;
  final CanvasDockData Function() dockData;
  final CanvasPresenceTileOverrides tileOverrides;
  final bool compact;
  final bool showShortToggle;
  final bool showPeerControls;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      // Tab goes banner action, board, dock, call tiles, view controls: reading order put the board's corners first.
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Stack(
          children: [
            FocusTraversalOrder(
              key: const ValueKey('canvas-surface'),
              order: const NumericFocusOrder(1),
              child: surface,
            ),
            CanvasSpeakingSync(cursors: cursors),
            if (showPeerControls)
              FocusTraversalOrder(
                key: const ValueKey('canvas-peer-controls'),
                order: const NumericFocusOrder(4),
                child: CanvasPeerControls(
                  participants: callParticipants,
                  cursors: cursors,
                  relay: viewRelay,
                  selfId: selfId,
                  onAcceptSummon: onAcceptSummon,
                ),
              ),
            if (paging case final paging?)
              CanvasPagingIndicator(paging: paging),
            FocusTraversalOrder(
              key: const ValueKey('canvas-notice'),
              order: const NumericFocusOrder(0),
              child: notice,
            ),
            FocusTraversalOrder(
              key: const ValueKey('canvas-dock'),
              order: const NumericFocusOrder(2),
              child: CanvasDockOverlay(
                call: callDock,
                canvas: dockData,
                tileOverrides: tileOverrides,
                compact: compact,
              ),
            ),
            if (showShortToggle)
              FocusTraversalOrder(
                key: const ValueKey('canvas-short-toggle'),
                order: const NumericFocusOrder(3),
                child: CanvasShortToggle(channelId: channelId),
              ),
            const FocusTraversalOrder(
              key: ValueKey('canvas-music-badge'),
              order: NumericFocusOrder(5),
              child: CanvasMusicBadge(),
            ),
          ],
        ),
      ),
    );
  }
}
