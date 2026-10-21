// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One screen-reader node per object in view, laid over the object itself,
/// so a note can be read and an object picked without a pointer (C-091).
///
/// Built only while assistive technology is on: it rebuilds with every camera
/// move, which nobody without a screen reader should pay for.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// More nodes than this in view is a wall of noise; the board's own label still counts them all.
const int _maxNodes = 40;

class CanvasBoardObjectSemantics extends StatefulWidget {
  const CanvasBoardObjectSemantics({
    super.key,
    required this.document,
    required this.onOpenActions,
  });

  final CanvasDocument document;

  /// Opens an object's own menu, as a long press on it does.
  final ValueChanged<String> onOpenActions;

  @override
  State<CanvasBoardObjectSemantics> createState() =>
      _CanvasBoardObjectSemanticsState();
}

class _CanvasBoardObjectSemanticsState
    extends State<CanvasBoardObjectSemantics> {
  bool _semantics = SemanticsBinding.instance.semanticsEnabled;

  @override
  void initState() {
    super.initState();
    SemanticsBinding.instance.addSemanticsEnabledListener(_onSemantics);
  }

  @override
  void dispose() {
    SemanticsBinding.instance.removeSemanticsEnabledListener(_onSemantics);
    super.dispose();
  }

  void _onSemantics() {
    final enabled = SemanticsBinding.instance.semanticsEnabled;
    if (enabled != _semantics) setState(() => _semantics = enabled);
  }

  @override
  Widget build(BuildContext context) {
    if (!_semantics) return const SizedBox.shrink();
    final document = widget.document;
    return Positioned.fill(
      child: ListenableBuilder(
        listenable: document,
        builder: (context, _) {
          final camera = document.camera;
          final selected = document.selectedObjectId.value;
          return Stack(
            children: [
              for (final id in document.visibleIds.take(_maxNodes))
                if (id != selected)
                  if (document.objectBounds(id) case final bounds?)
                    Positioned(
                      left: (bounds.x - camera.x) * camera.zoom,
                      top: (bounds.y - camera.y) * camera.zoom,
                      width: (bounds.w * camera.zoom).clamp(1, double.infinity),
                      height: (bounds.h * camera.zoom).clamp(
                        1,
                        double.infinity,
                      ),
                      child: Semantics(
                        container: true,
                        label: _labelFor(document, id),
                        onTap: () => document.selectedObjectId.value = id,
                        onLongPress: () => widget.onOpenActions(id),
                        child: const SizedBox.expand(),
                      ),
                    ),
            ],
          );
        },
      ),
    );
  }

  static String _labelFor(CanvasDocument document, String id) =>
      switch (document.kindOf(id)) {
        CanvasObjectKind.note => 'Note: ${document.textOf(id) ?? ''}',
        CanvasObjectKind.image => 'Image',
        CanvasObjectKind.shape => 'Shape',
        CanvasObjectKind.stroke || null => 'Drawing',
      };
}
