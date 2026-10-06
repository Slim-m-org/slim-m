// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's "Paste image" action: whether to offer it, and running it
/// against callbacks the composer supplies.
///
/// Split out of `composer.dart` rather than folded into its already-tight
/// line budget, and because this is more than the wrapper `_pickAttachment`
/// already has: reading the clipboard can fail in a way worth explaining
/// (see `composer_clipboard_image_stub.dart`'s [ClipboardImageReadException]),
/// where a file pick's own failures are already handled at the picker seam.
///
/// [composerClipboardPasteAvailable] is a plain [Future], never awaited
/// before opening the actions sheet: `showComposerActionsSheet` resolves it
/// itself, after the sheet is already on screen. Awaiting it first was
/// tried and reverted - a `MethodChannel` call with no handler registered
/// never completes inside a `testWidgets` pump cycle (confirmed directly;
/// it throws immediately in a bare `test()`, the only difference being
/// which zone the await runs in), so gating the sheet's very appearance on
/// it silently hung every existing test that opens this sheet without also
/// mocking a channel it has no reason to know about.
library;

import 'package:flutter/services.dart';

import 'composer_clipboard_image.dart';

/// Whether [event] is the paste chord, Ctrl+V or Cmd+V.
///
/// Deliberately not `KeyRepeatEvent`: holding the keys down should attach one
/// image, not one per repeat.
bool isClipboardPasteChord(KeyEvent event) {
  if (event is! KeyDownEvent) return false;
  if (event.logicalKey != LogicalKeyboardKey.keyV) return false;
  final keyboard = HardwareKeyboard.instance;
  return keyboard.isControlPressed || keyboard.isMetaPressed;
}

/// The Ctrl+V half, for the platforms with no event-driven route of their own.
///
/// **Never consumes the keystroke**, and the caller must not either: text
/// paste is Flutter's own and has to keep working untouched, so this only
/// ever runs alongside it. A clipboard holding text and no image reaches
/// [hasClipboardImage], gets false, and stops - the field's own paste is
/// what the person sees, exactly as before.
///
/// [hasClipboardImage] is asked first rather than reading straight away, so
/// a plain text paste stays a true no-op: [pasteClipboardImage] clears the
/// error banner as its first act, and every Ctrl+V wiping a failure the
/// person had not read yet would be its own small bug.
Future<void> pasteClipboardImageFromKeystroke(
  Future<void> Function(Uint8List bytes, String filename) stage,
  void Function(String? message) setError,
) async {
  if (!pasteKeystrokeReadsClipboardImage) return;
  if (!await hasClipboardImage()) return;
  await pasteClipboardImage(stage, setError);
}

/// Whether the "+" sheet's own "Paste image" row is worth offering.
///
/// Answers [hasClipboardImage] alone, on every platform - Android's and
/// Linux desktop's only route, and iOS's too, unconditionally.
///
/// This used to also answer false once the iOS edit-menu paste swizzle
/// (`ClipboardPasteBridge.m`) had installed, on the theory that the menu's own
/// Paste item made this row redundant. A real device disproved it
/// (2026-08-01): the swizzle installing is not evidence the menu item
/// appears, because Flutter's `SystemContextMenu` decides Paste's presence in
/// Dart from `Clipboard.hasStrings()` before any native call, until
/// `composer_context_menu.dart` forces the platform's Paste item in for an
/// image clipboard (confirmed working 2026-08-02, PR #327). So this row is
/// never hidden on that signal; only proof a paste completed through the
/// native menu would justify it, and nothing tracks that yet.
Future<bool> composerClipboardPasteAvailable() => hasClipboardImage();

/// Runs the whole "Paste image" action: clears [setError] up front, so a
/// retry that succeeds does not leave a stale failure on screen, then reads
/// the clipboard and either [stage]s the bytes (the composer's own
/// `_stageAttachment`, handed over directly rather than wrapped) or reports
/// a genuine read failure back through [setError].
/// Neither runs when the clipboard simply held no image - that is a silent
/// no-op, not a failure, the same way a cancelled file pick reports nothing.
Future<void> pasteClipboardImage(
  Future<void> Function(Uint8List bytes, String filename) stage,
  void Function(String? message) setError,
) async {
  setError(null);
  try {
    final bytes = await readClipboardImage();
    if (bytes != null) await stage(bytes, 'pasted-image.png');
  } on ClipboardImageReadException catch (e) {
    setError(e.message);
  }
}
