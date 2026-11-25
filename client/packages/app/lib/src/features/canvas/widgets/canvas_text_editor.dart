// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A text box typed where it sits: the box itself is the field, with its colour and size on a bar beside it.
///
/// Escape keeps what was there; a press outside the box and its bar, or Ctrl or Cmd plus Enter, commits.
/// Leaving the text empty cancels, since this field has no way to delete a box.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../providers/dock_reservation.dart';
import '../providers/canvas_pen_style.dart';
import '../providers/canvas_text_props.dart';
import '../../composer/widgets/composer_shortcode_convert.dart';
import '../../emoji/providers/emoji_catalog_provider.dart';
import 'canvas_inline_emoji_controller.dart';
import 'canvas_selection_bar.dart';
import 'canvas_text_content.dart';
import 'canvas_text_style_options.dart';

/// The tap region group the field, its selection menu and its bar share.
const Object canvasTextTapGroup = EditableText;

class CanvasTextEditor extends ConsumerStatefulWidget {
  const CanvasTextEditor({
    super.key,
    required this.document,
    required this.initial,
    required this.onSave,
    required this.onCancel,
    required this.onEscape,
    this.objectId,
    this.anchor = Offset.zero,
    this.spans,
  });

  final CanvasDocument document;

  /// The placed box being edited, or null for a new one at [anchor].
  final String? objectId;

  /// Where a new box goes, in world coordinates; ignored when [objectId] is set.
  final Offset anchor;
  final CanvasTextProps initial;

  /// How the board draws the text, so the box grows to what will be seen.
  final NoteSpanBuilder? spans;
  final ValueChanged<CanvasTextProps> onSave;

  /// An edit that ended with nothing to keep; the tool stays as it was.
  final VoidCallback onCancel;

  /// Escape ended the edit.
  final VoidCallback onEscape;

  @override
  ConsumerState<CanvasTextEditor> createState() => _CanvasTextEditorState();
}

class _CanvasTextEditorState extends ConsumerState<CanvasTextEditor> {
  late final _controller = InlineEmojiController(
    text: widget.initial.text,
    index: () => ref.read(customEmojiIndexProvider),
  )..selection = TextSelection.collapsed(offset: widget.initial.text.length);
  late final _focus = FocusNode()..addListener(_onFocusChange);
  late String _size = widget.initial.size;
  late String _colorKey = widget.initial.colorKey;
  bool _done = false;
  bool _full = false;

  @override
  void initState() {
    super.initState();
    widget.document.editingObjectId.value = widget.objectId;
    // Asked for, not autofocus alone: the pane's own shortcut focus can still hold it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    final document = widget.document;
    if (!document.isDisposed &&
        document.editingObjectId.value == widget.objectId) {
      document.editingObjectId.value = null;
    }
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  CanvasTextProps get _props =>
      CanvasTextProps(text: _controller.text, size: _size, colorKey: _colorKey);

  void _save() {
    if (_done) return;
    _done = true;
    final text = canonicalCustomEmojiText(
      _controller.text.trim(),
      ref.read(customEmojiIndexProvider),
    );
    final next = _props.copyWith(text: text);
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

  void _escape() {
    if (_done) return;
    _done = true;
    widget.onEscape();
  }

  void _markFull() {
    if (!_full) setState(() => _full = true);
  }

  /// The box the field fills, in world units: a placed box as it stands, grown to hold what is typed.
  Rect? _box() {
    final id = widget.objectId;
    final bounds = id == null ? null : widget.document.objectBounds(id);
    if (id != null && bounds == null) return null;
    final x = bounds?.x ?? widget.anchor.dx;
    final y = bounds?.y ?? widget.anchor.dy;
    final width = bounds?.w ?? defaultTextBoxWidth;
    final needed = textBoxFor(_props, width: width, spans: widget.spans).height;
    return Rect.fromLTWH(x, y, width, math.max(bounds?.h ?? 0, needed));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.document, _controller]),
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
        final rect = Rect.fromLTWH(
          (box.left - camera.x) * camera.zoom,
          (box.top - camera.y) * camera.zoom,
          box.width * camera.zoom,
          box.height * camera.zoom,
        );
        return Stack(
          children: [
            Positioned.fromRect(rect: rect, child: _field(context, camera)),
            if (_full) _fullNotice(context, rect),
            Positioned.fill(child: _bar(context, rect)),
          ],
        );
      },
    );
  }

  Widget _field(BuildContext context, Camera camera) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final ink = _colorKey == canvasDefaultTextColor
        ? tokens.textPrimary
        : resolveCanvasInk(
            canvasPenInkByKey,
            _colorKey,
            AppCanvasColors.annotation,
          );
    return TextFieldTapRegion(
      key: const ValueKey('canvas-text-editor-rect'),
      groupId: canvasTextTapGroup,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: tokens.accentFill),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Padding(
          padding: EdgeInsets.all(canvasTextPad * camera.zoom),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _save,
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _save,
              const SingleActivator(LogicalKeyboardKey.escape): _escape,
            },
            child: Semantics(
              label: 'Text box text',
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                inputFormatters: [TextBoxInputFormatter(onRefused: _markFull)],
                style: TextStyle(
                  fontFamily: AppFonts.sans,
                  fontSize: canvasTextFontSizes[_size]! * camera.zoom,
                  height: canvasTextLineHeight,
                  color: ink,
                ),
                cursorColor: tokens.accent,
                onTapOutside: (_) => _onTapOutside(context),
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
          ),
        ),
      ),
    );
  }

  Widget _fullNotice(BuildContext context, Rect rect) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Positioned(
      left: rect.left,
      top: rect.bottom + AppSpacing.s4,
      child: Text(
        'This text box is full.',
        style: AppText.caption.copyWith(color: tokens.dangerText),
      ),
    );
  }

  Widget _bar(BuildContext context, Rect anchor) {
    final dock =
        ref.watch(bottomDockReservationProvider) +
        AppSpacing.s12 +
        AppSpacing.s8;
    return CustomSingleChildLayout(
      delegate: CanvasSelectionBarLayout(
        anchor: anchor,
        bottomInset: [
          MediaQuery.viewInsetsOf(context).bottom,
          widget.document.bottomInset,
          dock,
        ].reduce(math.max),
      ),
      child: Semantics(
        container: true,
        label: 'Text style',
        child: CanvasSelectionBar(
          colour: canvasTextBarColour(context, _colorKey),
          colourLabel: 'Text colour',
          colourEntries: canvasTextColourEntries(
            context: context,
            ref: ref,
            colorKey: _colorKey,
            onColour: (colorKey) => _restyle(() => _colorKey = colorKey),
          ),
          size: canvasTextSizeEntry(
            _size,
            (size) => _restyle(() => _size = size),
          ),
          groupId: canvasTextTapGroup,
        ),
      ),
    );
  }

  void _restyle(VoidCallback change) {
    setState(change);
    _focus.requestFocus();
  }

  /// A press anywhere else in the app commits, unless a dialog opened from the editor is what was pressed.
  void _onTapOutside(BuildContext context) {
    if (ModalRoute.of(context)?.isCurrent ?? true) _save();
  }

  /// Another text field taking focus commits too, since a press into it never reaches the region.
  void _onFocusChange() {
    if (_focus.hasFocus || _done || !mounted) return;
    final now = FocusManager.instance.primaryFocus?.context;
    if (now?.findAncestorWidgetOfExactType<EditableText>() == null) return;
    _onTapOutside(context);
  }
}
