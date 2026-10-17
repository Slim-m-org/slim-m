// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Selection that travels: a list-owned accent bar that slides from the old
/// row to the new one, instead of two rows cross-fading their tints.
///
/// The layer owns the one marker and every row reports its own position;
/// per-row state structurally cannot slide between rows, which is why this
/// is a layer rather than a row decoration. [SelectionMarkerTarget] wraps a
/// row and, while selected, reports its rect (relative to the layer, so the
/// marker scrolls with the content it belongs to) after every build - a
/// reorder or a section growing above moves the row, and the rail rebuilds
/// on every change that can do that. The report is keyed by owner, so a
/// selected row unmounting (its channel deleted) retracts the marker rather
/// than stranding it. Reduce motion jumps the bar; it never animates a
/// row's own height, only its own position.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SelectionMarkerLayer extends StatefulWidget {
  const SelectionMarkerLayer({required this.child, super.key});

  final Widget child;

  static SelectionMarkerLayerState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<SelectionMarkerLayerState>();

  @override
  State<SelectionMarkerLayer> createState() => SelectionMarkerLayerState();
}

class SelectionMarkerLayerState extends State<SelectionMarkerLayer> {
  Rect? _rect;
  Object? _owner;

  /// The selected row's own rect, in this layer's coordinates - the same
  /// content coordinates the enclosing scroll view scrolls, regardless of
  /// which row reported it. Read by `CompactChannelRailDrawer` to scroll a
  /// freshly opened drawer to the selection: reused rather than a second
  /// row-geometry mechanism.
  Rect? get selectedRect => _rect;

  void report(Object owner, Rect rect) {
    if (_owner == owner && _rect == rect) return;
    setState(() {
      _owner = owner;
      _rect = rect;
    });
  }

  void retract(Object owner) {
    if (!mounted || _owner != owner) return;
    setState(() {
      _owner = null;
      _rect = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // This layer draws the one bar, so rows below must not draw their own.
        AppSelectionMarkerScope(child: widget.child),
        if (_rect case final rect?)
          AnimatedPositioned(
            duration: AppMotion.reduced(context, AppMotion.base),
            curve: AppMotion.entrance,
            left: 0,
            top: rect.top + 6,
            height: rect.height - 12,
            width: 3,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.accentFill,
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(AppRadii.full),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Wraps one selectable row; while [selected], keeps the enclosing
/// [SelectionMarkerLayer]'s bar on this row. Without a layer above it this
/// is a plain pass-through, so a row reused outside the rail pays nothing.
class SelectionMarkerTarget extends StatefulWidget {
  const SelectionMarkerTarget({
    required this.selected,
    required this.child,
    super.key,
  });

  final bool selected;
  final Widget child;

  @override
  State<SelectionMarkerTarget> createState() => _SelectionMarkerTargetState();
}

class _SelectionMarkerTargetState extends State<SelectionMarkerTarget> {
  SelectionMarkerLayerState? _layer;

  /// Post-frame, never inline: report and retract both `setState` on an
  /// ancestor, which throws mid-build - and dispose runs inside the build
  /// that removed this row, the same lock.
  void _afterFrame(void Function(SelectionMarkerLayerState layer) act) {
    final layer = _layer;
    if (layer == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (layer.mounted) act(layer);
    });
  }

  @override
  void dispose() {
    _afterFrame((layer) => layer.retract(this));
    super.dispose();
  }

  void _report() {
    _afterFrame((layer) {
      if (!mounted || !widget.selected) return;
      final box = context.findRenderObject() as RenderBox?;
      final layerBox = layer.context.findRenderObject() as RenderBox?;
      if (box == null || layerBox == null || !box.attached) return;
      final origin = box.localToGlobal(Offset.zero, ancestor: layerBox);
      layer.report(this, origin & box.size);
    });
  }

  @override
  Widget build(BuildContext context) {
    _layer = SelectionMarkerLayer.maybeOf(context);
    if (widget.selected) {
      _report();
    } else {
      _afterFrame((layer) => layer.retract(this));
    }
    return widget.child;
  }
}
