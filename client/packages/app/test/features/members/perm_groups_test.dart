// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `Perm.groups` is a second listing of the same bits `Perm.editable`
/// already names, hand-maintained alongside it; this pins the two from
/// drifting apart when a bit is added or renamed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';

void main() {
  test(
    'every editable bit but administrator appears in groups exactly once',
    () {
      final grouped = [
        for (final group in Perm.groups)
          for (final spec in group.permissions) spec.bit,
      ];
      final editableNonAdmin = Perm.editable
          .map((p) => p.$1)
          .where((bit) => bit != Perm.administrator)
          .toList();

      expect(grouped.toSet(), editableNonAdmin.toSet());
      expect(
        grouped.length,
        grouped.toSet().length,
        reason: 'no bit repeats across groups',
      );
      expect(grouped.length, editableNonAdmin.length);
    },
  );

  test('gridRows is groups flattened in the same order', () {
    final flattened = [for (final group in Perm.groups) ...group.permissions];
    expect(Perm.gridRows, flattened);
  });

  test('every label and description is non-empty', () {
    for (final group in Perm.groups) {
      expect(group.title, isNotEmpty);
      for (final spec in group.permissions) {
        expect(spec.label, isNotEmpty);
        expect(spec.description, isNotEmpty);
      }
    }
  });

  test('the design-confirmed elevated permissions are tagged', () {
    final elevated = {
      for (final group in Perm.groups)
        for (final spec in group.permissions)
          if (spec.elevated) spec.bit,
    };
    expect(
      elevated,
      containsAll([Perm.manageRoles, Perm.kickMembers, Perm.banMembers]),
    );
  });
}
