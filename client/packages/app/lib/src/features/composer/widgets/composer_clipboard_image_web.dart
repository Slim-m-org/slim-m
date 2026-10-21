// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web implementation: the browser's `paste` event hands over bytes with no permission prompt; only a tapped "Paste image" uses `navigator.clipboard.read()`.
/// State is module-level (the seam is top-level functions): the newest caller gets the paste and hands it back when it stops. [hasClipboardImage] stays false, as the browser cannot check ahead.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// False here: the browser hands the bytes over on its own `paste` event, so a polling keystroke would stage the image twice.
const bool pasteKeystrokeReadsClipboardImage = false;

/// A pasted image's bytes and filename, also the ownership token [stopClipboardImagePaste] checks; duplicated from the stub because conditional-import siblings cannot share it.
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

/// The web half of the exception type, declared here too because conditional-import siblings must both define it or dart2js fails while `dart analyze` passes.
/// Thrown when the browser refuses a tapped clipboard read.
class ClipboardImageReadException implements Exception {
  const ClipboardImageReadException(this.message);

  /// A sentence fit to show, not a raw platform error string.
  final String message;

  @override
  String toString() => message;
}
