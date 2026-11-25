// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reads a browser `blob:` URL and frees it.
library;

export 'blob_url_read_io.dart'
    if (dart.library.js_interop) 'blob_url_read_web.dart';
