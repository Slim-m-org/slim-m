// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart' show BoxHitTestResult, RenderProxyBox;

/// Hides its child from pointers only. IgnorePointer also blocks semantics
/// actions, which left a screen reader's tap on a hidden control doing nothing.
class CanvasPointerGate extends SingleChildRenderObjectWidget {
  const CanvasPointerGate({super.key, required this.ignoring, super.child});

  final bool ignoring;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderCanvasPointerGate(ignoring);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderCanvasPointerGate renderObject,
  ) => renderObject.ignoring = ignoring;
}

class RenderCanvasPointerGate extends RenderProxyBox {
  RenderCanvasPointerGate(this.ignoring);

  bool ignoring;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      !ignoring && super.hitTest(result, position: position);
}
