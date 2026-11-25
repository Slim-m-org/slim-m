// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A browser's file drop, taken from the window's own drag events.
///
/// `desktop_drop` throws on any dragged item that is not a file (a picture
/// dragged from another page also carries its address and markup as text), and
/// hands every file over as one whole-blob read. This keeps only the file
/// items and reads each in bounded slices.
library;

export 'web_file_drop_stub.dart'
    if (dart.library.js_interop) 'web_file_drop_web.dart';
