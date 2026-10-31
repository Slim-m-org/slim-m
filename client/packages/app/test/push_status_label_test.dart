// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every push status the settings screen can show has a label, and two states
/// must never share one or read blank: the label is the only thing that tells
/// a user whether notifications are working or why they are not, so a
/// copy-paste that duplicates one, or a new state left unlabelled, would hide a
/// real difference behind identical text.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';

void main() {
  test('every push status has a non-empty, distinct label', () {
    final seen = <String>{};
    for (final status in PushStatus.values) {
      final label = status.label;
      expect(label, isNotEmpty, reason: '$status has no label');
      expect(
        seen.add(label),
        isTrue,
        reason: 'two statuses share the label "$label"',
      );
    }
  });
}
