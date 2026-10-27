// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_pane.dart';

/// The text tool and the in-place editors, split out of `_CanvasPaneState` for its line budget.
extension _CanvasPaneText on _CanvasPaneState {
  /// Opens the editor for a new text box at [world]; nothing is sent until it is saved with text.
  void _onTextPlace(Offset world) {
    final error = ref.read(canvasEngineProvider(widget.channelId)).error;
    if (canvasErrorBlocksDrawing(error)) return;
    _refresh(() => _textDraft = world);
  }

  /// A finger held on empty canvas opens the same editor the text tool does.
  void _onSelectLongPress(Offset world) {
    if (_tool != CanvasTool.pan) return;
    if (hitTestTopmost(_document, world, touch: true) != null) return;
    _document.selectedObjectId.value = null;
    _onTextPlace(world);
  }

  CanvasTextProps get _newTextProps {
    final last = ref.read(canvasLastTextStyleProvider);
    return CanvasTextProps(text: '', size: last.size, colorKey: last.colorKey);
  }

  /// The editor for whichever text box or note is open, or null.
  Widget? _activeEditor() {
    final editing = _editingNoteId;
    if (editing != null && _document.kindOf(editing) == CanvasObjectKind.text) {
      final box = _document.textBoxOf(editing);
      if (box == null) return null;
      return CanvasTextEditor(
        key: ValueKey(editing),
        document: _document,
        objectId: editing,
        initial: CanvasTextProps(
          text: box.text,
          size: box.size,
          colorKey: box.colorKey,
        ),
        onSave: (props) => unawaited(_onTextEditSave(editing, props)),
        onCancel: _onNoteEditCancel,
      );
    }
    if (editing != null) {
      return CanvasNoteEditor(
        key: ValueKey(editing),
        document: _document,
        objectId: editing,
        onSave: (text) => unawaited(_onNoteEditSave(editing, text)),
        onCancel: _onNoteEditCancel,
      );
    }
    final draft = _textDraft;
    if (draft == null) return null;
    return CanvasTextEditor(
      key: ValueKey(draft),
      document: _document,
      anchor: draft,
      initial: _newTextProps,
      onSave: (props) => unawaited(_onTextDraftSave(draft, props)),
      onCancel: _onNoteEditCancel,
    );
  }

  Future<void> _onTextDraftSave(Offset world, CanvasTextProps props) async {
    final startedWith = _tool;
    _refresh(() => _textDraft = null);
    ref.read(canvasLastTextStyleProvider.notifier).state = (
      size: props.size,
      colorKey: props.colorKey,
    );
    final placed = await _quickPlacement.placeText(
      world,
      props,
      onError: _engine.reportError,
    );
    if (!_mounted) return;
    _boardFocusNode.requestFocus();
    if (placed != null) _selectPlaced(placed.id, startedWith: startedWith);
  }

  Future<void> _onTextEditSave(String id, CanvasTextProps props) async {
    _refresh(() => _editingNoteId = null);
    ref.read(canvasLastTextStyleProvider.notifier).state = (
      size: props.size,
      colorKey: props.colorKey,
    );
    _boardFocusNode.requestFocus();
    await _ops.editText(id, props);
    _refresh();
  }
}
