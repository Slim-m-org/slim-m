// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web implementation: the browser's own `paste` DOM event, which hands
/// over pasted bytes directly with no extra permission prompt.
///
/// Ctrl+V goes through the `paste` event, which needs no permission. Only a
/// tapped "Paste image" uses the async `navigator.clipboard.read()`, whose
/// permission prompt that tap can carry. Only an item whose MIME type starts with `image/` is treated as a
/// pasted image; anything else (plain text, the common case) is left alone,
/// so the browser's own default paste still lands wherever Flutter's text
/// field is really backed by an `<input>` or `<textarea>`.
///
/// State is module-level because the seam is a pair of top-level functions;
/// the newest caller gets the paste, and a caller that stops hands it back to
/// the one it started over (an open canvas under a focused composer).
///
/// [hasClipboardImage] stays false: the browser cannot check the clipboard
/// ahead of a real paste without a prompt, so the composer's poll-gated
/// "Paste image" row stays hidden on web.
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

final _handlers = <PastedImageHandler>[];
JSFunction? _listener;

/// Starts listening for a pasted image; call once per focus gained, paired
/// with [stopClipboardImagePaste] on focus lost.
void startClipboardImagePaste(PastedImageHandler onImage) {
  // == rather than identical(): two tear-offs of one instance method are == but never identical.
  _handlers
    ..removeWhere((h) => h == onImage)
    ..add(onImage);
  if (_listener != null) return;
  final listener = _handlePaste.toJS;
  _listener = listener;
  web.document.addEventListener('paste', listener);
}

/// Stops [onImage]'s turn; an earlier caller still listening gets the paste
/// back. A stale stop from a composer losing focus once tore down the open
/// canvas's listener, so this never touches another caller's registration.
void stopClipboardImagePaste(PastedImageHandler onImage) {
  _handlers.removeWhere((h) => h == onImage);
  if (_handlers.isEmpty) _teardown();
}

void _teardown() {
  final listener = _listener;
  if (listener != null) {
    web.document.removeEventListener('paste', listener);
  }
  _listener = null;
}

/// Always false: see this file's doc comment for why the browser cannot
/// answer this without a permission prompt of its own.
Future<bool> hasClipboardImage() async => false;

/// The clipboard's first image, for a tapped "Paste image"; null when it
/// holds none. The browser may refuse the read, which is reported.
Future<Uint8List?> readClipboardImage() async {
  try {
    final items = (await web.window.navigator.clipboard.read().toDart).toDart;
    for (final item in items) {
      for (final type in item.types.toDart) {
        final mime = type.toDart;
        if (!mime.startsWith('image/')) continue;
        final blob = await item.getType(mime).toDart;
        final buffer = await blob.arrayBuffer().toDart;
        return buffer.toDart.asUint8List();
      }
    }
    return null;
  } catch (_) {
    throw const ClipboardImageReadException(
      'The browser did not let this page read the clipboard. Try Ctrl+V.',
    );
  }
}

void _handlePaste(web.ClipboardEvent event) =>
    unawaited(_readPastedImage(event));

Future<void> _readPastedImage(web.ClipboardEvent event) async {
  final onImage = _handlers.isEmpty ? null : _handlers.last;
  final data = event.clipboardData;
  final items = data?.items;
  if (onImage == null || data == null || items == null) return;
  // Copied cells or a document carry text beside their picture; pasted into a text field, the text is what was meant.
  if (_targetsTextField(event) && data.getData('text/plain').isNotEmpty) {
    return;
  }
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

bool _targetsTextField(web.Event event) {
  final target = event.target;
  if (target == null || !target.isA<web.HTMLElement>()) return false;
  final element = target as web.HTMLElement;
  return element.isA<web.HTMLInputElement>() ||
      element.isA<web.HTMLTextAreaElement>() ||
      element.isContentEditable;
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
/// Thrown here when the browser refuses a tapped clipboard read.
class ClipboardImageReadException implements Exception {
  const ClipboardImageReadException(this.message);

  /// A sentence fit to show, not a raw platform error string.
  final String message;

  @override
  String toString() => message;
}
