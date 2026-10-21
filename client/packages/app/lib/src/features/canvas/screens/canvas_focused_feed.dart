// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One call tile's live feed filling the canvas pane, painted under the ink so drawings and cursors stay on top.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../messages/widgets/media_label.dart';
import 'canvas_presence_geometry.dart';

/// How long a feed may be gone before the focus is dropped; a voice reconnect
/// empties the roster for a moment and brings the same people back.
const Duration focusedFeedGrace = Duration(seconds: 4);

class CanvasFocusedFeed extends StatefulWidget {
  const CanvasFocusedFeed({
    super.key,
    required this.document,
    required this.tileKey,
    required this.participants,
    required this.cameraViewFor,
    required this.screenShareViewFor,
    required this.onLost,
  });

  /// Held at fit while the feed shows, so ink stays over the part of the picture it was drawn on.
  final CanvasDocument document;
  final String tileKey;
  final List<VoiceParticipant> participants;
  final CameraViewBuilder cameraViewFor;
  final ScreenShareViewBuilder screenShareViewFor;

  /// Called when the feed ended, or its person stayed gone past [focusedFeedGrace], so the focus can be dropped.
  final VoidCallback onLost;

  @override
  State<CanvasFocusedFeed> createState() => _CanvasFocusedFeedState();
}

class _CanvasFocusedFeedState extends State<CanvasFocusedFeed> {
  Timer? _lostTimer;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    widget.document.addListener(_holdFit);
    _holdFit();
  }

  @override
  void didUpdateWidget(covariant CanvasFocusedFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      oldWidget.document.removeListener(_holdFit);
      widget.document.addListener(_holdFit);
    }
  }

  @override
  void dispose() {
    widget.document.removeListener(_holdFit);
    _lostTimer?.cancel();
    super.dispose();
  }

  // The feed fills the pane while the ink follows the camera, so any zoom or pan would put a stroke over a different part of the picture.
  void _holdFit() {
    if (_holding ||
        widget.document.isFitted ||
        widget.document.viewport.isEmpty) {
      return;
    }
    _holding = true;
    widget.document.fitBoard();
    _holding = false;
  }

  // A roster that lost the person may be a reconnect; one that still lists them without the feed means it ended.
  void _syncLostTimer({required bool live, required bool present}) {
    if (live) {
      _lostTimer?.cancel();
      _lostTimer = null;
      return;
    }
    if (present) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onLost());
      return;
    }
    _lostTimer ??= Timer(focusedFeedGrace, widget.onLost);
  }

  @override
  Widget build(BuildContext context) {
    final tileKey = widget.tileKey;
    final isScreen = presenceTileKind(tileKey) == screenTrackKind;
    final identity = presenceTileIdentity(tileKey);
    final participant = widget.participants
        .where((p) => p.identity == identity)
        .firstOrNull;
    final live =
        participant != null &&
        (isScreen ? participant.isScreenSharing : participant.isCameraOn);
    _syncLostTimer(live: live, present: participant != null);
    if (!live) return const SizedBox.shrink();
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: isScreen
                  ? widget.screenShareViewFor(identity)
                  : widget.cameraViewFor(identity),
            ),
            Positioned(
              left: AppSpacing.s12,
              top: AppSpacing.s12,
              child: MediaLabelChip(
                icon: isScreen ? AppIcons.screenShare : AppIcons.camera,
                label: isScreen
                    ? presenceScreenLabel(participant)
                    : (participant.isLocal ? 'Your camera' : participant.name),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
