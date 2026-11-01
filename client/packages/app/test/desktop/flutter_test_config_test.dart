// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// That `flutter_test_config.dart` actually ran.
///
/// The hook is picked up by filename and nothing fails if it is renamed,
/// deleted or moved - the suite simply goes back to printing a drift warning
/// and a ten-frame stack trace per database, which is noise rather than a
/// failure and so would not be noticed for a long time. This asserts the
/// effect rather than the file, so it survives the file being reorganised and
/// fails if the hook stops being applied.
library;

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the per-binary test config applied its drift setting', () {
    expect(
      driftRuntimeOptions.dontWarnAboutMultipleDatabases,
      isTrue,
      reason:
          'flutter_test_config.dart did not run for this binary; see its '
          'own doc for why the warning it silences is a false positive here',
    );
  });
}
