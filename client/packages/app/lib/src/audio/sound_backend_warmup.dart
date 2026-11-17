// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Readies the sound backend before the first cue, so no cue pays for it.
library;

export 'sound_backend_warmup_none.dart'
    if (dart.library.ffi) 'sound_backend_warmup_ffi.dart';
