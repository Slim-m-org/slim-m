// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every test starts with an empty mock preferences store, so a surface that
/// reads preferences never reaches the real plugin, which has no host here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('preferences are readable without a test installing a mock', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });
}
