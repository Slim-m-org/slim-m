// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Linux microphones and speakers from the sound server; a no-op on web.
library;

export 'pulse_audio_parse.dart';
export 'pulse_audio_web.dart' if (dart.library.io) 'pulse_audio_io.dart';
