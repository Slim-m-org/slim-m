// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tool buttons in two groups: pan, pen and eraser, then what places an object.
/// The selected pen, note, shape, connect or stamp gains a caret (and a long-press)
/// for its options, through the same controls-with-options pattern the call dock uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart';
import '../providers/armed_stamp.dart';
import '../providers/canvas_edge_style.dart';
import '../providers/canvas_note_style.dart';
import '../providers/canvas_pen_style.dart';
import '../widgets/canvas_edge_controls.dart';
import '../widgets/canvas_custom_colours.dart';
import '../widgets/canvas_note_style_options.dart';
import '../widgets/stamp_picker.dart';
import '../widgets/stamp_tool_button.dart';
import 'canvas_dock_group.dart';
import 'canvas_shape_icons.dart';
import 'canvas_tool_model.dart';
import 'canvas_tool_options.dart';

const _cannotDrawTooltip = "Can't draw right now";

class CanvasToolButtons extends ConsumerWidget {
  const CanvasToolButtons({
    super.key,
    required this.tool,
    required this.onToolChanged,
    required this.canDraw,
    required this.shapeKind,
    required this.onShapeKindChanged,
    required this.pen,
    required this.onPenChanged,
  });

  final CanvasTool tool;
  final ValueChanged<CanvasTool> onToolChanged;
  final bool canDraw;
  final CanvasShapeKind shapeKind;
  final ValueChanged<CanvasShapeKind> onShapeKindChanged;
  final CanvasPenStyle pen;
  final ValueChanged<CanvasPenStyle> onPenChanged;

  /// A second press on the armed tool puts it down, like every other dock toggle.
  void _pick(CanvasTool picked) =>
      onToolChanged(tool == picked ? CanvasTool.pan : picked);

  /// With nothing armed yet, the first press opens the picker beside the button.
  Widget _stampButton(WidgetRef ref) => StampToolButton(
    active: tool == CanvasTool.stamp,
    semanticLabel: 'Stamp',
    tooltip: canDraw ? 'Stamp (M)' : _cannotDrawTooltip,
    onPressed: !CanvasTool.stamp.isAvailable(canDraw: canDraw)
        ? null
        : (anchor) =>
              tool != CanvasTool.stamp &&
                  ref.read(armedStampProvider).content == null
              ? showStampPicker(
                  anchor,
                  onPicked: (_) => onToolChanged(CanvasTool.stamp),
                )
              : _pick(CanvasTool.stamp),
  );

  /// The picker's caret only exists while the tool is down, like the pen's and the shape's.
  Widget _stampWithCaret(WidgetRef ref) => Builder(
    builder: (anchor) => AppControlWithOptions(
      active: true,
      visualHeight: AppSizes.icon28,
      optionsLabel: 'Choose a stamp',
      onOpenOptions: tool == CanvasTool.stamp
          ? () => showStampPicker(anchor, onPicked: (_) {})
          : null,
      child: _stampButton(ref),
    ),
  );

  /// Options belong to the selected tool only, and only while it can be used.
  List<ControlOptionEntry> _optionsFor(
    BuildContext context,
    WidgetRef ref,
    CanvasTool forTool,
  ) {
    if (tool != forTool || !forTool.isAvailable(canDraw: canDraw)) {
      return const [];
    }
    if (forTool == CanvasTool.connect) return _edgeOptions(context, ref);
    if (forTool == CanvasTool.note) {
      if (!ref.watch(canvasNoteStyleSupportedProvider)) return const [];
      return canvasNoteStyleOptions(
        context: context,
        ref: ref,
        style: ref.watch(canvasLastNoteStyleProvider),
        onChanged: (next) =>
            ref.read(canvasLastNoteStyleProvider.notifier).state = next,
      );
    }
    void choose(String key) => onPenChanged(pen.copyWith(colorKey: key));
    return canvasToolOptions(
      forTool,
      pen: pen,
      onPenChanged: onPenChanged,
      shapeKind: shapeKind,
      onShapeKindChanged: onShapeKindChanged,
      colours: forTool == CanvasTool.pen
          ? canvasColourRow(
              context: context,
              ref: ref,
              defaults: canvasPenColourSwatches(
                selectedKey: pen.colorKey,
                onChoose: choose,
              ),
              selectedKey: pen.colorKey,
              onChoose: choose,
            )
          : null,
    );
  }

  List<ControlOptionEntry> _edgeOptions(BuildContext context, WidgetRef ref) {
    final style = ref.watch(canvasActiveEdgeStyleProvider);
    void set(CanvasEdgeStyle next) =>
        ref.read(canvasActiveEdgeStyleProvider.notifier).state = next;
    return canvasEdgeControls(
      context: context,
      ref: ref,
      tokens: Theme.of(context).extension<AppTokens>()!,
      colorKey: style.colorKey,
      arrow: style.arrow,
      onColour: (key) => set(
        key == null
            ? style.copyWith(clearColor: true)
            : style.copyWith(colorKey: key),
      ),
      onArrow: (arrow) => set(style.copyWith(arrow: arrow)),
    );
  }

  /// The caret only exists once the tool is selected, so the hint says what is true now.
  String get _shapeHint {
    final armed = 'Shape (S) · ${canvasShapeKindLabel(shapeKind)} armed, ';
    return tool == CanvasTool.shape
        ? '${armed}change it from the caret beside the tool'
        : '${armed}select it to choose another';
  }

  Widget _withOptions(
    BuildContext context,
    WidgetRef ref,
    CanvasTool forTool,
    String label,
    Widget child, {
    bool showCaret = true,
  }) => ControlOptionsMenu(
    active: true,
    showCaret: showCaret,
    menuWidth: _toolMenuWidth,
    caretHeight: AppSizes.icon28,
    opensAbove: true,
    optionsLabel: label,
    options: _optionsFor(context, ref, forTool),
    child: child,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pan = AppIconButton(
      icon: AppIcons.pan,
      semanticLabel: 'Pan',
      tooltip:
          'Pan (H) · pan the canvas, move an object, or select a stroke '
          'to reorder it · hold Shift while resizing to flip '
          'the aspect lock',
      active: tool == CanvasTool.pan,
      onPressed: () => onToolChanged(CanvasTool.pan),
    );
    final penButton = _withOptions(
      context,
      ref,
      CanvasTool.pen,
      'Pen options',
      _PenButton(
        pen: pen,
        active: tool == CanvasTool.pen,
        canDraw: canDraw,
        onPressed: CanvasTool.pen.isAvailable(canDraw: canDraw)
            ? () => _pick(CanvasTool.pen)
            : null,
      ),
    );
    final eraser = AppIconButton(
      icon: AppIcons.eraser,
      semanticLabel: 'Eraser',
      tooltip:
          'Eraser (E) · erases ink and shapes. Right-click or long-press a '
          'note or image, then Delete',
      active: tool == CanvasTool.eraser,
      onPressed: () => _pick(CanvasTool.eraser),
    );
    final note = _withOptions(
      context,
      ref,
      CanvasTool.note,
      'Note options',
      AppIconButton(
        icon: AppIcons.note,
        semanticLabel: 'Note',
        tooltip: canDraw ? 'Note (N)' : _cannotDrawTooltip,
        active: tool == CanvasTool.note,
        onPressed: CanvasTool.note.isAvailable(canDraw: canDraw)
            ? () => _pick(CanvasTool.note)
            : null,
      ),
      // A long press or right click opens it: a caret would not fit the dock at 360dp.
      showCaret: false,
    );
    final text = AppIconButton(
      icon: AppIcons.textBox,
      semanticLabel: 'Text',
      tooltip: canDraw ? 'Text (T)' : _cannotDrawTooltip,
      active: tool == CanvasTool.text,
      onPressed: CanvasTool.text.isAvailable(canDraw: canDraw)
          ? () => _pick(CanvasTool.text)
          : null,
    );
    final shape = _withOptions(
      context,
      ref,
      CanvasTool.shape,
      'Shape options',
      AppIconButton(
        // The armed kind's own glyph, not a generic one - state must be visible, not just remembered.
        icon: canvasShapeKindIcon(shapeKind),
        semanticLabel: 'Shape',
        tooltip: canDraw ? _shapeHint : _cannotDrawTooltip,
        active: tool == CanvasTool.shape,
        onPressed: CanvasTool.shape.isAvailable(canDraw: canDraw)
            ? () => _pick(CanvasTool.shape)
            : null,
      ),
    );
    final connect = _withOptions(
      context,
      ref,
      CanvasTool.connect,
      'Connection options',
      AppIconButton(
        icon: AppIcons.connect,
        semanticLabel: 'Connect',
        tooltip: canDraw
            ? 'Connect (C) \u00b7 drag from one object to another'
            : _cannotDrawTooltip,
        active: tool == CanvasTool.connect,
        onPressed: CanvasTool.connect.isAvailable(canDraw: canDraw)
            ? () => _pick(CanvasTool.connect)
            : null,
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: canvasDockGroups(context, [
        [pan, penButton, eraser],
        [
          note,
          text,
          shape,
          if (ref.watch(canvasEdgesSupportedProvider)) connect,
          if (ref.watch(canvasStampsSupportedProvider)) _stampWithCaret(ref),
        ],
      ]),
    );
  }
}

/// Room for the six pen colours and the picker at the 30dp pointer target.
const double _toolMenuWidth = 240;

/// The pen button, with a bar of the armed colour under the glyph, like the tip of the nib.
class _PenButton extends StatelessWidget {
  const _PenButton({
    required this.pen,
    required this.active,
    required this.canDraw,
    required this.onPressed,
  });

  final CanvasPenStyle pen;
  final bool active;
  final bool canDraw;
  final VoidCallback? onPressed;

  /// Drops the bar to just under the 20px glyph, whatever the button's own height.
  static const double _barOffset = 19;
  static const double _barLength = 14;

  /// Grows with the armed width, so the bar still says thin or thick.
  double get _barThickness => (pen.width / 2).clamp(2, 4).toDouble();

  @override
  Widget build(BuildContext context) {
    final outline = penBarOutline(pen.color);
    // Joined to its caret the glyph's box sits right in the hit box, so the bar follows it there.
    final joined = AppControlWithOptions.joinedOf(context);
    return Stack(
      children: [
        AppIconButton(
          icon: AppIcons.pen,
          semanticLabel: 'Pen',
          tooltip: canDraw ? 'Pen (P)' : _cannotDrawTooltip,
          active: active,
          onPressed: onPressed,
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Align(
              alignment: joined ? Alignment.centerRight : Alignment.center,
              child: SizedBox.square(
                dimension: AppSizes.icon28,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: _barOffset),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: outline == null
                            ? null
                            : Border.all(color: outline, width: 0.75),
                        borderRadius: BorderRadius.circular(_barThickness),
                      ),
                      child: Container(
                        key: const ValueKey('pen-colour-bar'),
                        width: _barLength,
                        height: _barThickness,
                        decoration: BoxDecoration(
                          color: pen.color,
                          borderRadius: BorderRadius.circular(_barThickness),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A hairline for a near-black or near-white pen, which would vanish into the dark or light surface.
@visibleForTesting
Color? penBarOutline(Color colour) {
  final luminance = colour.computeLuminance();
  if (luminance < 0.05) return const Color(0x99FFFFFF);
  if (luminance > 0.85) return const Color(0x99000000);
  return null;
}
