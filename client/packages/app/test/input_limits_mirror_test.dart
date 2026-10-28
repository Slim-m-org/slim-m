// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screens read the server's caps from `InputLimits` rather than keeping a
/// second copy that can drift.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/widgets/sign_in_error.dart';
import 'package:slimm_app/src/features/settings/screens/admin/emoji_name.dart';

void main() {
  test('display name and emoji name caps are the shared limits', () {
    expect(displayNameMaxLength, InputLimits.name);
    expect(maxEmojiNameLength, InputLimits.emojiName);
  });
}
