// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A text box typed and styled where it sits: a raised panel over the box, or over the tapped point for a box not placed yet.
///
/// Escape or Cancel keeps what was there; Save, Ctrl or Cmd plus Enter, or a click outside commits.
/// Leaving the text empty cancels, since this panel has no way to delete a box.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_swatch_row.dart';
import '../providers/canvas_pen_style.dart';
import 'canvas_editor_layout.dart';
import '../providers/canvas_text_props.dart';
import 'canvas_text_content.dart';

class CanvasTextEditor extends StatefulWidget {
  const CanvasTextEditor({
    super.key,
    required this.document,
    required this.initial,
    required this.onSave,
    required this.onCancel,
    this.objectId,
    this.anchor = Offset.zero,
  });

  final CanvasDocument document;

  /// The placed box being edited, or null for a new one at [anchor].
  final String? objectId;

  /// Where a new box goes, in world coordinates; ignored when [objectId] is set.
  final Offset anchor;
  final CanvasTextProps initial;
  final ValueChanged<CanvasTextProps> onSave;
  final VoidCallback onCancel;

  @override
  State<CanvasTextEditor> createState() => _CanvasTextEditorState();
}

class _CanvasTextEditorState extends State<CanvasTextEditor> {
  late final _controller = TextEditingController(text: widget.initial.text)
    ..selection = TextSelection.collapsed(offset: widget.initial.text.length);
  final _focus = FocusNode();
  late String _size = widget.initial.size;
  late String _colorKey = widget.initial.colorKey;
  bool _done = false;
  bool _full = false;

  @override
  void initState() {
    super.initState();
    // Asked for, not autofocus alone: the pane's own shortcut focus can still hold it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (_done) return;
    _done = true;
    final next = CanvasTextProps(
      text: _controller.text.trim(),
      size: _size,
      colorKey: _colorKey,
    );
    if (next.text.isEmpty || next == widget.initial) {
      widget.onCancel();
    } else {
      widget.onSave(next);
    }
  }

  void _cancel() {
    if (_done) return;
    _done = true;
    widget.onCancel();
  }

  void _markFull() {
    if (!_full) setState(() => _full = true);
  }

  Rect? _box() {
    final id = widget.objectId;
    if (id == null) {
      return Rect.fromLTWH(
        widget.anchor.dx,
        widget.anchor.dy,
        defaultTextBoxWidth,
        0,
      );
    }
    final bounds = widget.document.objectBounds(id);
    return bounds == null
        ? null
        : Rect.fromLTWH(bounds.x, bounds.y, bounds.w, bounds.h);
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Stack(
      children: [
        Positioned.fill(
          // Named, so the cover a screen reader meets over the board says what a tap on it does.
          child: Semantics(
            label: 'Save and close the text box',
            button: true,
            onTap: _save,
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _save,
            ),
          ),
        ),
        Positioned.fill(
          child: AnimatedBuilder(
            animation: widget.document,
            builder: (context, _) {
              final box = _box();
              if (box == null) {
                // The box was removed under the editor.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _cancel();
                });
                return const SizedBox.shrink();
              }
              final camera = widget.document.camera;
              final board = widget.document.board;
              return CustomSingleChildLayout(
                delegate: CanvasEditorLayout(
                  area: board == null
                      ? null
                      : Rect.fromLTWH(
                          (board.left - camera.x) * camera.zoom,
                          (board.top - camera.y) * camera.zoom,
                          board.width * camera.zoom,
                          board.height * camera.zoom,
                        ),
                  anchor: Offset(
                    (box.left - camera.x) * camera.zoom,
                    (box.top - camera.y) * camera.zoom,
                  ),
                  objectWidth: box.width * camera.zoom,
                  keyboardInset: inset,
                  bottomInset: widget.document.bottomInset,
                ),
                child: _panel(context),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _panel(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s8),
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border.all(color: tokens.accentFill),
          borderRadius: BorderRadius.circular(AppRadii.card),
          boxShadow: AppShadows.menu,
        ),
        // Scrolls so a short window, or a keyboard, cannot overflow the panel.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(tokens),
              if (_full)
                Text(
                  'This text box is full.',
                  style: AppText.caption.copyWith(color: tokens.dangerText),
                ),
              const SizedBox(height: AppSpacing.s4),
              ControlSwatchRow(swatches: _sizeSwatches(tokens), close: () {}),
              ControlSwatchRow(swatches: _colourSwatches(tokens), close: () {}),
              const SizedBox(height: AppSpacing.s4),
              Align(
                alignment: Alignment.centerRight,
                // Wraps: a sideways phone with its keyboard up leaves the panel narrower than both buttons.
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: AppSpacing.s8,
                  runSpacing: AppSpacing.s4,
                  children: [
                    AppButton(
                      label: 'Cancel',
                      variant: AppButtonVariant.ghost,
                      size: AppButtonSize.sm,
                      onPressed: _cancel,
                    ),
                    AppButton(
                      label: 'Save',
                      variant: AppButtonVariant.primary,
                      size: AppButtonSize.sm,
                      onPressed: _save,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(AppTokens tokens) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: Semantics(
        label: 'Text box text',
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          minLines: 2,
          maxLines: 6,
          keyboardType: TextInputType.multiline,
          inputFormatters: [TextBoxInputFormatter(onRefused: _markFull)],
          style: AppText.body.copyWith(color: tokens.textPrimary),
          cursorColor: tokens.accent,
          decoration: const InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            isDense: true,
            contentPadding: EdgeInsets.zero,
            hintText: 'Text',
          ),
        ),
      ),
    );
  }

  List<ControlSwatch> _sizeSwatches(AppTokens tokens) => [
    for (final key in canvasTextSizeKeys)
      ControlSwatch(
        label: '${canvasTextSizeLabels[key]} text',
        selected: _size == key,
        onSelected: () => setState(() => _size = key),
        mark: Text(
          'A',
          style: canvasTextSizeSample(key).copyWith(color: tokens.textPrimary),
        ),
      ),
  ];

  List<ControlSwatch> _colourSwatches(AppTokens tokens) => [
    ControlSwatch(
      label: 'Default colour',
      selected: _colorKey == canvasDefaultTextColor,
      onSelected: () => setState(() => _colorKey = canvasDefaultTextColor),
      color: tokens.textPrimary,
    ),
    for (final choice in canvasPenColors)
      ControlSwatch(
        label: choice.label,
        selected: _colorKey == choice.key,
        onSelected: () => setState(() => _colorKey = choice.key),
        color: choice.color,
      ),
  ];
}
