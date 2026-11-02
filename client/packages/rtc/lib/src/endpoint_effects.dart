// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Windows audio effects on the capture endpoint in use; null elsewhere.
library;

export 'endpoint_effects_parse.dart';
export 'endpoint_effects_web.dart'
    if (dart.library.io) 'endpoint_effects_io.dart';
