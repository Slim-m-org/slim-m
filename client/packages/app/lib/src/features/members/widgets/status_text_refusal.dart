// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Why the server would refuse a status line, checked before it is sent so the
/// status already set is never touched by a save that cannot land.
library;

import 'package:slimm_api/api.dart' show InputLimits;
import 'package:slimm_design_system/design_system.dart' show inputCharCount;

import '../../../hidden_characters.dart';

/// The sentence to show for [text], or null when it can be saved.
String? statusTextRefusal(String text) {
  if (inputCharCount(text) > InputLimits.statusText) {
    return 'A status can be at most ${InputLimits.statusText} characters.';
  }
  if (hidesTextOutsideEmoji(text)) return hiddenCharactersRefusal;
  return null;
}
