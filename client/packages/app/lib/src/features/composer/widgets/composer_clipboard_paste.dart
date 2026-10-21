// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's "Paste image" action: whether to offer it, and running it
/// against callbacks the composer supplies.
///
/// Split out of `composer.dart` rather than folded into its already-tight
/// line budget, and because this is more than the wrapper `ComposerAttachmentActions.pickAttachment`
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

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'composer_clipboard_image.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

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
///
/// Never on iOS any more: the long-press menu's own Paste takes an image there
/// (`composer_context_menu.dart`, PR #327), and the owner confirmed it on a
/// device on 2026-10-14, so the row only repeated it. Android keeps the row,
/// because its long-press Paste is text only.
Future<bool> composerClipboardPasteAvailable({
  required TargetPlatform platform,
}) =>
    platform == TargetPlatform.iOS ? Future.value(false) : hasClipboardImage();

/// Runs the whole "Paste image" action: clears [setError] up front, so a
/// retry that succeeds does not leave a stale failure on screen, then reads
/// the clipboard and either [stage]s the bytes (the composer's own
/// `ComposerAttachmentActions.stageAttachment`, handed over directly rather than wrapped) or reports
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
    if (bytes == null || bytes.isEmpty) {
      setError('No image on the clipboard.');
      return;
    }
    await stage(await clipboardImageAsPng(bytes), 'pasted-image.png');
  } on ClipboardImageReadException catch (e, stack) {
    AppLog.swallowed(
      LogTag.ui,
      'Could not paste the clipboard image',
      e,
      stack,
    );
    setError(e.message);
  }
}

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// The widest side a clipboard image may have before it is refused rather than decoded.
const int maxClipboardImageSide = 8192;

/// [bytes] as PNG, re-encoding another format (a Windows clipboard bitmap) so
/// what is staged matches the name it is uploaded under.
@visibleForTesting
Future<Uint8List> clipboardImageAsPng(Uint8List bytes) async {
  if (bytes.length >= _pngSignature.length &&
      Iterable<int>.generate(
        _pngSignature.length,
      ).every((i) => bytes[i] == _pngSignature[i])) {
    return bytes;
  }
  ui.Codec? codec;
  ui.Image? image;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > maxClipboardImageSide ||
        descriptor.height > maxClipboardImageSide) {
      descriptor.dispose();
      throw const ClipboardImageReadException(
        'That image is too large to paste.',
      );
    }
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw const FormatException('no PNG encoder');
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } on ClipboardImageReadException {
    rethrow;
  } catch (_) {
    throw const ClipboardImageReadException(
      'The clipboard image could not be read.',
    );
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
