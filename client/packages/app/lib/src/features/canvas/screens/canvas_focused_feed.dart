// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One call tile's live feed filling the canvas pane, painted under the ink
/// so drawings, images and cursors stay on top of it.
///
/// This is what "full screen" on a canvas tile means: the feed grows to the
/// pane and the canvas stays, where the voice screen's fullscreen route would
/// have covered it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../messages/widgets/media_label.dart';
import 'canvas_presence_geometry.dart';

class CanvasFocusedFeed extends StatelessWidget {
  const CanvasFocusedFeed({
    super.key,
    required this.tileKey,
    required this.participants,
    required this.cameraViewFor,
    required this.screenShareViewFor,
    required this.onLost,
  });

  final String tileKey;
  final List<VoiceParticipant> participants;
  final CameraViewBuilder cameraViewFor;
  final ScreenShareViewBuilder screenShareViewFor;

  /// Called after the frame when the feed stopped being live, so the focus can be dropped.
  final VoidCallback onLost;

  @override
  Widget build(BuildContext context) {
    final isScreen = presenceTileKind(tileKey) == screenTrackKind;
    final identity = presenceTileIdentity(tileKey);
    final participant = participants
        .where((p) => p.identity == identity)
        .firstOrNull;
    final live =
        participant != null &&
        (isScreen ? participant.isScreenSharing : participant.isCameraOn);
    if (!live) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onLost());
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: isScreen
                  ? screenShareViewFor(identity)
                  : cameraViewFor(identity),
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
