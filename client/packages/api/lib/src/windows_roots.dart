// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [installWindowsRootFetching], a no-op off dart:io.
library;

export 'windows_roots_stub.dart' if (dart.library.io) 'windows_roots_io.dart'
    show installWindowsRootFetching;
