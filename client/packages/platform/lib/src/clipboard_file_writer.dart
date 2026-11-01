// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Putting a whole file on the system clipboard, the way a file manager's Copy
/// does, so pasting it into another app hands over the file itself.
///
/// The bytes land in a temporary file first, since the clipboard on Linux and
/// Windows carries a path, not the contents.
library;

import 'dart:typed_data';

import 'clipboard_file_writer_io.dart'
    if (dart.library.js_interop) 'clipboard_file_writer_web.dart' as impl;

/// A file copy the platform refused or could not perform.
class ClipboardFileWriteException implements Exception {
  const ClipboardFileWriteException(this.message);

  /// A sentence fit to show, not a raw platform error string.
  final String message;

  @override
  String toString() => message;
}

abstract class ClipboardFileWriter {
  /// Whether this platform can put a file on the clipboard at all.
  bool get supported;

  /// Copies [bytes] as a file named [filename].
  ///
  /// Throws [ClipboardFileWriteException] when the platform refuses.
  Future<void> writeFile(Future<Uint8List> bytes, {required String filename});
}

class PlatformClipboardFileWriter implements ClipboardFileWriter {
  const PlatformClipboardFileWriter();

  @override
  bool get supported => impl.supported;

  @override
  Future<void> writeFile(Future<Uint8List> bytes, {required String filename}) =>
      impl.writeFile(bytes, filename: filename);
}
