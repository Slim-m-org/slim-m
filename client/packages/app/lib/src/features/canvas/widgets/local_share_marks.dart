// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The marks viewers draw, shown over the sharer's own preview of their share.
///
/// Only while viewers may draw, so a window share, a GNOME sharer or a phone
/// still sees them in the app when no overlay window can show them.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../screen_overlay/providers/screen_overlay_controller.dart';
import '../../voice/providers/share_zoom_controller.dart';
import 'screen_annotate_layer.dart';

class LocalShareMarks extends ConsumerWidget {
  const LocalShareMarks({
    super.key,
    required this.sharerId,
    required this.sharerName,
    required this.tileRect,
    this.zoom,
  });

  final String sharerId;
  final String sharerName;
  final Rect tileRect;
  final ShareZoomController? zoom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(screenOverlayControllerProvider);
    // Still a Positioned: a loose child would shrink the all-positioned Stack this lives in.
    if (!state.consenting) {
      return const Positioned(width: 0, height: 0, child: SizedBox.shrink());
    }
    return ScreenAnnotateLayer(
      sharerId: sharerId,
      sharerName: sharerName,
      tileRect: tileRect,
      zoom: zoom,
      readOnly: true,
      fallbackAspect: state.aspect,
    );
  }
}
