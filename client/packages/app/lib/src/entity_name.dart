// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one name rule for channels and categories, mirroring the server's
/// `validate_channel_name` and `validate_category_name`.
library;

import 'package:slimm_api/api.dart' show InputLimits;
import 'package:slimm_design_system/design_system.dart' show inputCharCount;

/// The server's ceiling, refused here rather than round-tripping first.
const int entityNameMaxChars = InputLimits.name;

bool entityNameValid(String raw) {
  final length = inputCharCount(raw);
  return length > 0 && length <= entityNameMaxChars;
}
