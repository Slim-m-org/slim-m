// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screens read the server's caps from `InputLimits` rather than keeping a
/// second copy that can drift.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/screens/admin/emoji_name.dart';

void main() {
  test('emoji name cap is the shared limit', () {
    expect(maxEmojiNameLength, InputLimits.emojiName);
  });
}
