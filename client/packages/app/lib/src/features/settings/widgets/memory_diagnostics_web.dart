// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web side of the resident-size read: the web has no `dart:io`
/// [ProcessInfo], and `performance.memory` measures only the JS heap (not the
/// CanvasKit WASM heap), so it would mislead rather than inform. The readout
/// says so instead of showing a number that is wrong.
library;

int? currentResidentBytes() => null;
