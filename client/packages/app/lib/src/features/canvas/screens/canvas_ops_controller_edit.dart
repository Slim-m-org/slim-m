// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_ops_controller.dart';

/// One note edit and the text it replaced, which an undo puts back.
class _EditEntry extends _UndoEntry {
  _EditEntry(this.objectId, this.fromText);

  final String objectId;
  final String fromText;
}

/// The text an undone edit left, which a redo writes again.
class _RedoEdit extends _RedoEntry {
  _RedoEdit(this.objectId, this.toText);

  final String objectId;
  final String toText;
}

/// Editing a placed note, sharing the undo ledger the other gestures use.
extension CanvasOpsControllerEdit on CanvasOpsController {
  /// Replaces [objectId]'s text, shown at once and pushed onto the undo
  /// stack once the server accepts it. Returns whether the text changed.
  Future<bool> editNote(String objectId, String text) async {
    final before = document.noteTextOf(objectId);
    if (before == null || before == text || isLocked(objectId)) return false;
    final submitted = await _editTo(
      objectId,
      text,
      'That note could not be edited.',
    );
    if (submitted == null) return false;
    _pushUndo(_EditEntry(objectId, submitted));
    return true;
  }

  Future<_RedoEntry?> _undoEdit(String objectId, String text) async {
    final before = await _editTo(objectId, text, 'That could not be undone.');
    return before == null ? null : _RedoEdit(objectId, before);
  }

  Future<_UndoEntry?> _redoEdit(String objectId, String text) async {
    final before = await _editTo(objectId, text, 'That could not be redone.');
    return before == null ? null : _EditEntry(objectId, before);
  }

  /// Writes [text] locally first, for the same immediate feedback a drag
  /// gives, and returns the text it replaced; null when the request failed
  /// (the old text is put back) or the note is gone from this client.
  Future<String?> _editTo(
    String objectId,
    String text,
    String errorMessage,
  ) async {
    final before = document.noteTextOf(objectId);
    if (before == null) return null;
    document.setNoteText(objectId, text);
    document.refresh();
    try {
      await client.submitCanvasOp(
        channelId,
        id: newCanvasOpId(),
        kind: 'edit',
        objectId: objectId,
        props: {'text': text},
      );
      return before;
    } on api.ApiException {
      document.setNoteText(objectId, before);
      document.refresh();
      onError(errorMessage);
      return null;
    }
  }
}
