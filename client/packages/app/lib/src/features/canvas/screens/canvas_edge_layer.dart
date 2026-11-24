// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selection bar of a connection: its colour, its arrow, its label and delete (decision 0137).
///
/// At 600 and wider it floats above the connection, below it when there is no room. Under 600 it docks full width at the pane's foot above the dock and the keyboard, and scrolls sideways; a finger never has to reach a floating surface.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_swatch_row.dart';
import '../widgets/canvas_edge_controls.dart';
import 'canvas_engine.dart';
import 'canvas_ops_controller.dart';

/// Names the label field, for tests that type into it.
const canvasEdgeLabelFieldKey = ValueKey<String>('connection-label-field');

/// How far above a connection a floating bar sits, and how wide the room it needs is.
const double _gap = 12;
const double _barHeight = 56;

class CanvasEdgeLayer extends ConsumerStatefulWidget {
  const CanvasEdgeLayer({
    super.key,
    required this.channelId,
    required this.document,
    required this.canManage,
    required this.selfId,
  });

  final String channelId;
  final CanvasDocument document;
  final bool canManage;
  final String? selfId;

  @override
  ConsumerState<CanvasEdgeLayer> createState() => _CanvasEdgeLayerState();
}

class _CanvasEdgeLayerState extends ConsumerState<CanvasEdgeLayer> {
  final _label = TextEditingController();
  final _focus = FocusNode(debugLabel: 'connection label');
  String? _editing;

  CanvasEdges get _edges => widget.document.edges;
  CanvasOpsController get _ops =>
      ref.read(canvasEngineProvider(widget.channelId).notifier).ops;

  @override
  void initState() {
    super.initState();
    _edges.labelEdit.addListener(_onLabelRequest);
    widget.document.selectedObjectId.addListener(_onSelection);
  }

  @override
  void dispose() {
    _edges.labelEdit.removeListener(_onLabelRequest);
    widget.document.selectedObjectId.removeListener(_onSelection);
    _label.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _mayEdit(CanvasEdge edge) =>
      widget.canManage ||
      (edge.authorId != null && edge.authorId == widget.selfId);

  void _onLabelRequest() {
    final id = _edges.labelEdit.value;
    final edge = _edges.liveEdge(id);
    if (id == null || edge == null || !_mayEdit(edge)) {
      _edges.labelEdit.value = null;
      return;
    }
    _label.text = edge.spec.label ?? '';
    _label.selection = TextSelection.collapsed(offset: _label.text.length);
    setState(() => _editing = id);
    _focus.requestFocus();
  }

  /// Selecting something else keeps what was typed, the way a note does.
  void _onSelection() {
    if (_editing != null &&
        widget.document.selectedObjectId.value != _editing) {
      _commit();
    }
  }

  void _commit() {
    final id = _editing;
    if (id == null) return;
    final text = _label.text.trim();
    _close();
    final held = _edges.liveEdge(id)?.spec.label;
    if (text == (held ?? '')) return;
    _ops.editEdge(id, {'label': text.isEmpty ? null : text});
  }

  void _close() {
    _edges.labelEdit.value = null;
    if (mounted) setState(() => _editing = null);
    widget.document.selectedObjectId.value == null ? null : _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: ListenableBuilder(
      listenable: Listenable.merge([
        widget.document,
        widget.document.selectedObjectId,
      ]),
      builder: (context, _) {
        final edge = _edges.selected;
        final route = edge == null ? null : _edges.routeOf(edge);
        if (edge == null || route == null || !_mayEdit(edge)) {
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (context, box) {
            final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
            final bar = _bar(context, edge, compact: compact);
            return Stack(
              children: [
                compact
                    ? _docked(context, bar)
                    : _floating(box.biggest, route, bar),
              ],
            );
          },
        );
      },
    ),
  );

  Widget _docked(BuildContext context, Widget bar) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: widget.document.bottomInset + keyboard,
      child: bar,
    );
  }

  Widget _floating(Size pane, EdgeRoute route, Widget bar) {
    final camera = widget.document.camera;
    final at = Offset(
      (route.midpoint.dx - camera.x) * camera.zoom,
      (route.midpoint.dy - camera.y) * camera.zoom,
    );
    final above = at.dy - _barHeight - _gap >= AppSpacing.s8;
    final top = above ? at.dy - _barHeight - _gap : at.dy + _gap + 24;
    return Positioned(
      left: (at.dx - 190).clamp(
        AppSpacing.s8,
        pane.width - 380 - AppSpacing.s8,
      ),
      top: top.clamp(AppSpacing.s8, pane.height - _barHeight - AppSpacing.s8),
      child: bar,
    );
  }

  Widget _bar(BuildContext context, CanvasEdge edge, {required bool compact}) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = AppTouchTargets.of(context);
    final body = _editing == edge.id
        ? _labelField(tokens, compact: compact)
        : _controls(context, tokens, edge, touch: touch);
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(compact ? 0 : AppRadii.card),
        boxShadow: compact ? const [] : AppShadows.menu,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s8),
        child: compact
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: body,
              )
            : body,
      ),
    );
    return Semantics(
      container: true,
      label: 'Connection options',
      child: TapRegion(
        onTapOutside: _editing == null ? null : (_) => _commit(),
        child: surface,
      ),
    );
  }

  Widget _labelField(AppTokens tokens, {required bool compact}) {
    final field = CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: AppInput(
        key: canvasEdgeLabelFieldKey,
        controller: _label,
        focusNode: _focus,
        autofocus: true,
        placeholder: 'Label',
        size: AppInputSize.sm,
        maxLength: maxEdgeLabelChars,
        semanticLabel: 'Connection label',
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _commit(),
      ),
    );
    return Row(
      mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
      children: [
        compact ? Expanded(child: field) : SizedBox(width: 260, child: field),
        const SizedBox(width: AppSpacing.s4),
        AppIconButton(
          icon: AppIcons.check,
          semanticLabel: 'Save label',
          onPressed: _commit,
        ),
      ],
    );
  }

  Widget _controls(
    BuildContext context,
    AppTokens tokens,
    CanvasEdge edge, {
    required bool touch,
  }) {
    final entries = canvasEdgeControls(
      context: context,
      ref: ref,
      tokens: tokens,
      colorKey: edge.spec.colorKey,
      arrow: edge.spec.arrow,
      onColour: (key) => _ops.editEdge(edge.id, {'color': key}),
      onArrow: (arrow) => _ops.editEdge(edge.id, {'arrow': arrow.name}),
    );
    final swatches = entries.whereType<ControlSwatchGroup>().first.swatches;
    final arrow = entries.whereType<ControlSegmented>().first;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: swatches.length * (touch ? AppSizes.rowTouch : 32.0),
          child: ControlSwatchRow(swatches: swatches, close: () {}),
        ),
        const SizedBox(width: AppSpacing.s8),
        AppSegmentedControl.inline(
          options: arrow.options,
          selectedIndex: arrow.selectedIndex,
          onSegmentSelected: arrow.onSelected,
          semanticLabel: arrow.label,
        ),
        const SizedBox(width: AppSpacing.s4),
        AppIconButton(
          icon: AppIcons.edit,
          semanticLabel: 'Edit label',
          tooltip: 'Edit label (Enter)',
          onPressed: () => _edges.labelEdit.value = edge.id,
        ),
        AppIconButton(
          icon: AppIcons.delete,
          semanticLabel: 'Delete connection',
          tooltip: 'Delete (Del)',
          onPressed: () => _ops.eraseEdge(edge.id),
        ),
      ],
    );
  }
}
