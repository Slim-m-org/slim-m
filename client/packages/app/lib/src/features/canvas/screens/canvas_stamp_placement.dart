// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The board's Stamp tool (decision 0121): a tap places the armed stamp at
/// 130 world units on its longest side, a drag sizes it around the press up
/// to 324, and from then on it is an ordinary item that stays.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../screen_overlay/providers/stamp_content.dart';
import '../widgets/stamp_picker.dart';
import '../widgets/stamp_view.dart';
import 'canvas_quick_placement.dart';

/// 12% and 30% of the shared area's 1080-unit height, as on a share.
const double boardStampDefaultSide = 130;
const double boardStampMaxSide = 324;
const double boardStampMinSide = 43;

/// The Stamp tool from a key or the wheel with nothing armed: the picker opens over the middle of [pane].
void showBoardStampPicker(BuildContext pane, {required VoidCallback onPicked}) {
  final box = pane.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return;
  final middle = box.localToGlobal(box.size.center(Offset.zero));
  showStampPicker(
    pane,
    anchorRect: Rect.fromCenter(center: middle, width: 0, height: 0),
    onPicked: (_) => onPicked(),
  );
}

class CanvasStampPlacement {
  CanvasStampPlacement({
    required this.placement,
    required this.armed,
    required this.aspectOf,
    required this.onShown,
    required this.onError,
  });

  final CanvasQuickPlacement Function() placement;
  final StampContent? Function() armed;
  final double? Function(StampContent content) aspectOf;

  /// Runs once the stamp shows on the board, before the server answers, so its bitmap can start.
  final VoidCallback onShown;
  final void Function(String message) onError;

  /// The stamp a drag is sizing, in world units, for the preview.
  final ghost = ValueNotifier<({Offset centre, double side})?>(null);

  void drag(Offset centre, double? side) => ghost.value = side == null
      ? null
      : (
          centre: centre,
          side: side.clamp(boardStampMinSide, boardStampMaxSide),
        );

  Future<void> place(Offset world, double? side) async {
    ghost.value = null;
    final stamp = armed();
    if (stamp == null) return;
    final placed = placement().placeStamp(
      world,
      stamp,
      side: side == null
          ? boardStampDefaultSide
          : side.clamp(boardStampMinSide, boardStampMaxSide),
      aspect: aspectOf(stamp) ?? 1,
      onError: onError,
    );
    onShown();
    await placed;
  }

  void dispose() => ghost.dispose();
}

/// The stamp a drag on the board is sizing, drawn where it will land.
class CanvasStampGhost extends StatelessWidget {
  const CanvasStampGhost({
    super.key,
    required this.document,
    required this.placement,
  });

  final CanvasDocument document;
  final CanvasStampPlacement placement;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ValueListenableBuilder(
      valueListenable: placement.ghost,
      builder: (context, ghost, _) {
        final stamp = placement.armed();
        if (ghost == null || stamp == null) return const SizedBox.shrink();
        final camera = document.camera;
        final aspect = placement.aspectOf(stamp) ?? 1;
        final side = ghost.side * camera.zoom;
        final centre = Offset(
          (ghost.centre.dx - camera.x) * camera.zoom,
          (ghost.centre.dy - camera.y) * camera.zoom,
        );
        return Stack(
          children: [
            Positioned.fromRect(
              rect: Rect.fromCenter(
                center: centre,
                width: aspect >= 1 ? side : side * aspect,
                height: aspect >= 1 ? side / aspect : side,
              ),
              child: StampView(content: stamp),
            ),
          ],
        );
      },
    ),
  );
}
