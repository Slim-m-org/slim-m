// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Asks a browser to confirm before its tab closes or reloads while staged
/// attachments, which live in memory only, would be lost.
library;

export 'unload_guard_stub.dart'
    if (dart.library.js_interop) 'unload_guard_web.dart';
