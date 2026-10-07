// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web implementation: the browser's own `paste` DOM event, which hands
/// over pasted bytes directly with no extra permission prompt.
///
/// This deliberately does not use the async `navigator.clipboard.read()`
/// API: that one needs an explicit clipboard-read permission grant, while a
/// `paste` event is the browser's ordinary reaction to Ctrl+V and needs
/// none. Only an item whose MIME type starts with `image/` is treated as a
/// pasted image; anything else (plain text, the common case) is left alone,
/// so the browser's own default paste still lands wherever Flutter's text
/// field is really backed by an `<input>` or `<textarea>`.
///
/// State here is module-level rather than per-instance because the seam it
/// backs ([startClipboardImagePaste]) is itself a pair of top-level
/// functions: only one composer is ever focused at a time, so one active
/// listener is all this needs to hold.
///
/// [hasClipboardImage] and [readClipboardImage] are the mobile seam's
/// poll-and-tap pair (see `composer_clipboard_image_stub.dart`); the browser
/// has no permission-free way to check clipboard contents ahead of a real
/// paste, so both are no-ops here and the "Paste image" row they gate never
/// shows on web - Ctrl+V through the listener above is already the way in.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// False here: the browser hands the bytes over on its own
/// `paste` event, so a keystroke that also polled would stage the same image
/// twice. [hasClipboardImage] answers false on web anyway, so this is belt
/// and braces rather than the only thing stopping it.
const bool pasteKeystrokeReadsClipboardImage = false;

/// A pasted image's bytes and a filename, also the ownership token
/// [stopClipboardImagePaste] checks - declared independently of the stub's
/// own copy since the two are conditional-import siblings, the same reason
/// [ClipboardImageReadException] below is duplicated rather than shared.
typedef PastedImageHandler = void Function(Uint8List bytes, String filename);

PastedImageHandler? _onImage;
JSFunction? _listener;

/// Starts listening for a pasted image; call once per focus gained, paired
/// with [stopClipboardImagePaste] on focus lost.
void startClipboardImagePaste(PastedImageHandler onImage) {
  _teardown();
  _onImage = onImage;
  final listener = _handlePaste.toJS;
  _listener = listener;
  web.document.addEventListener('paste', listener);
}

/// Stops listening, but only while [onImage] is still the registered
/// callback - not merely "safe to call even if nothing was ever started",
/// which was this function's whole contract before a real race exposed the
/// gap in it: the canvas pane's own doc once reasoned that an unmounting
/// caller's stop "would silently replace this one anyway" if a newer caller
/// had already started, which is backwards when the *unmounting* caller's
/// stop is the one that runs second. A composer losing focus right as the
/// canvas opened called this after the canvas's own `start()` had already
/// taken over, and since both shared one unconditional global, the
/// composer's stale `stop()` tore down the canvas's listener - paste then
/// did nothing, silently, because `_onImage` read null on every keystroke
/// after. Found by an end-to-end scenario driving a real paste on the
/// canvas, never by a widget test, since nothing here exercised two
/// callers racing for the same global.
void stopClipboardImagePaste(PastedImageHandler onImage) {
  // == rather than identical(): two tear-offs of one instance method are == but never identical.
  if (_onImage == onImage) _teardown();
}

void _teardown() {
  final listener = _listener;
  if (listener != null) {
    web.document.removeEventListener('paste', listener);
  }
  _listener = null;
  _onImage = null;
}

/// Always false: see this file's doc comment for why the browser cannot
/// answer this without a permission prompt of its own.
Future<bool> hasClipboardImage() async => false;

/// Always null, matching [hasClipboardImage].
Future<Uint8List?> readClipboardImage() async => null;

void _handlePaste(web.ClipboardEvent event) =>
    unawaited(_readPastedImage(event));

Future<void> _readPastedImage(web.ClipboardEvent event) async {
  final onImage = _onImage;
  final items = event.clipboardData?.items;
  if (onImage == null || items == null) return;
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (!item.type.startsWith('image/')) continue;
    final file = item.getAsFile();
    if (file == null) continue;
    // Stops the browser also treating this as a text or file-drop paste.
    event.preventDefault();
    final buffer = await file.arrayBuffer().toDart;
    onImage(buffer.toDart.asUint8List(), _filenameFor(item.type));
    return;
  }
}

String _filenameFor(String mimeType) {
  final extension = switch (mimeType) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'png',
  };
  return 'pasted-image.$extension';
}

/// The web half of the seam's exception type.
///
/// Declared here as well as in the stub because the two are conditional-
/// import siblings: a caller writing `on ClipboardImageReadException` must
/// compile on every target, and a type that exists on one side only fails
/// dart2js while passing `dart analyze` outright. That is exactly how the
/// web build broke without any gate noticing.
///
/// Nothing on this target throws it - the browser paste event hands over
/// bytes or nothing - but the type must exist for the catch to compile.
class ClipboardImageReadException implements Exception {
  const ClipboardImageReadException(this.message);

  /// A sentence fit to show, not a raw platform error string.
  final String message;

  @override
  String toString() => message;
}
