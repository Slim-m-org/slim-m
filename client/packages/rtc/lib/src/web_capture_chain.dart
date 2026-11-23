// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fork's capture chain in a browser; nothing outside one.
library;

export 'web_capture_chain_io.dart'
    if (dart.library.js_interop) 'web_capture_chain_web.dart';
