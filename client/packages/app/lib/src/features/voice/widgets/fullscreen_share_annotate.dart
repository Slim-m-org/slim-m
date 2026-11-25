// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The draw-on-their-screen layer over a remote share opened full screen.
library;

import 'package:flutter/material.dart';

import '../../canvas/widgets/screen_annotate_layer.dart';
import '../providers/share_zoom_controller.dart';

/// Fills the stage exactly as the video does, so a mark lands where the sharer's screen is.
class FullscreenShareAnnotate extends StatelessWidget {
  const FullscreenShareAnnotate({
    super.key,
    required this.sharerId,
    required this.sharerName,
    required this.zoom,
    required this.toolbarBottom,
  });

  final String sharerId;
  final String sharerName;
  final ShareZoomController zoom;

  /// Clears the call dock the stage lays over its bottom edge.
  final double toolbarBottom;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: LayoutBuilder(
      builder: (context, box) => Stack(
        clipBehavior: Clip.none,
        children: [
          ScreenAnnotateLayer(
            key: const ValueKey('fullscreen-annotate'),
            sharerId: sharerId,
            sharerName: sharerName,
            tileRect: Offset.zero & box.biggest,
            zoom: zoom,
            shareToolState: true,
            toolbarBottom: toolbarBottom,
          ),
        ],
      ),
    ),
  );
}
