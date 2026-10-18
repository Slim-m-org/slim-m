// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The callback the voice pieces use to say what they decided, at what level.
library;

import 'package:slimm_api/api.dart' show LogLevel;

typedef VoiceLog = void Function(String message, {LogLevel level});
