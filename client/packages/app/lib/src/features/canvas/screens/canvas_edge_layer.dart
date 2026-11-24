// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selection bar of a connection: its colour, its arrow, its label and delete (decision 0137).
///
/// At 600 and wider it floats above the connection, below it when there is no room. Under 600 it docks full width at the pane's foot above the dock and the keyboard, and scrolls sideways; a finger never has to reach a floating surface.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../hidden_characters.dart';
import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_swatch_row.dart';
import '../../../providers/dock_reservation.dart';
import '../widgets/canvas_edge_controls.dart';
import '../widgets/canvas_selection_bar.dart';
import 'canvas_engine.dart';
import 'canvas_ops_controller.dart';

/// Names the label field, for tests that type into it.
const canvasEdgeLabelFieldKey = ValueKey<String>('connection-label-field');

/// The height a label chip takes around a connection's midpoint, which a floating bar stays clear of.
const double _chipClearance = 32;

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
    final text = _cleanLabel(_label.text);
    _close();
    final held = _edges.liveEdge(id)?.spec.label;
    if (text == (held ?? '')) return;
    _ops.editEdge(id, {'label': text.isEmpty ? null : text});
  }

  /// What the server accepts: no hidden characters and at most [maxEdgeLabelChars] scalar values, which a grapheme count does not guarantee.
  String _cleanLabel(String raw) {
    var text = raw.trim();
    if (hidesTextOutsideEmoji(text)) {
      text = String.fromCharCodes(
        text.runes.where((c) => !isHiddenCharacter(c)),
      ).trim();
    }
    final runes = text.runes.toList();
    if (runes.length <= maxEdgeLabelChars) return text;
    return String.fromCharCodes(runes.take(maxEdgeLabelChars)).trim();
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
            final compact = box.maxWidth < canvasSelectionBarDockWidth;
            return Consumer(
              builder: (context, ref, _) => CustomSingleChildLayout(
                delegate: CanvasSelectionBarLayout(
                  anchor: _anchor(route),
                  bottomInset: _bottomInset(context, ref),
                ),
                child: _bar(context, edge, compact: compact),
              ),
            );
          },
        );
      },
    ),
  );

  /// The middle of the connection on screen, wide enough that a floating bar clears its label chip.
  Rect _anchor(EdgeRoute route) {
    final camera = widget.document.camera;
    final at = Offset(
      (route.midpoint.dx - camera.x) * camera.zoom,
      (route.midpoint.dy - camera.y) * camera.zoom,
    );
    return Rect.fromCenter(center: at, width: 0, height: _chipClearance);
  }

  /// The most the foot of the pane is covered by: the keyboard, the call's own inset, or the floating dock with its margins.
  double _bottomInset(BuildContext context, WidgetRef ref) {
    final dock =
        ref.watch(bottomDockReservationProvider) +
        AppSpacing.s12 +
        AppSpacing.s8;
    return [
      MediaQuery.viewInsetsOf(context).bottom,
      widget.document.bottomInset,
      dock,
    ].reduce(math.max);
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
        borderRadius: BorderRadius.circular(AppRadii.card),
        boxShadow: AppShadows.menu,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s8),
        child: compact && _editing == null
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
        child: UnconstrainedBox(
          constrainedAxis: Axis.horizontal,
          child: surface,
        ),
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
