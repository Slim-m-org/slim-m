// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The plain snapshot registry names a route and viewports and nothing else,
/// so two entries on one route at one viewport render the same pixels under
/// different names: `dm` and `dm-normal-transcript` did.
library;

import 'package:flutter_test/flutter_test.dart';

import '../support/surface_registry.dart';

void main() {
  test('no two registered surfaces render the same route at one viewport', () {
    final seen = <String, String>{};
    final clashes = <String>[];
    for (final surface in snapshotSurfaces.entries) {
      for (final viewport in surface.value.viewports) {
        final key = '${surface.value.route} @ $viewport';
        final first = seen.putIfAbsent(key, () => surface.key);
        if (first != surface.key) {
          clashes.add('$key: $first and ${surface.key}');
        }
      }
    }

    expect(clashes, isEmpty);
  });
}
