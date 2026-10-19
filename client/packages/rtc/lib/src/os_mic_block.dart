// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether Windows privacy settings block the microphone; false elsewhere.
library;

export 'os_mic_block_parse.dart';
export 'os_mic_block_web.dart' if (dart.library.io) 'os_mic_block_io.dart';
