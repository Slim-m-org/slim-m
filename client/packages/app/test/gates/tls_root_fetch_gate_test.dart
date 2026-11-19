// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every dart:io client goes through `RootFetchingHttpOverrides`, which only
/// holds while `main` installs it before the first connection and nothing
/// else replaces `HttpOverrides.global` (decision 0056, Windows addendum).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slimm_test_support/source_gates.dart';

const _installer = 'api/lib/src/windows_roots_io.dart';

void main() {
  test('main installs root fetching before anything can connect', () {
    final main = codeOnly(File('lib/main.dart').readAsStringSync());
    final install = main.indexOf('installWindowsRootFetching()');
    expect(install, isNonNegative);
    for (final later in ['countLaunch(', 'runApp(', 'DesktopWindowShell(']) {
      expect(main.indexOf(later), greaterThan(install), reason: later);
    }
  });

  test('nothing else replaces HttpOverrides.global', () {
    final assigns = RegExp(r'HttpOverrides\s*\.\s*global\s*=(?!=)');
    final packages = Directory('..');
    final offenders = [
      for (final file
          in packages
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where(
                (f) =>
                    f.path.endsWith('.dart') &&
                    f.path.contains('${Platform.pathSeparator}lib') &&
                    !f.path.contains('.dart_tool'),
              ))
        if (assigns.hasMatch(codeOnly(file.readAsStringSync())))
          file.path.substring(packages.path.length + 1),
    ];
    expect(offenders, [_installer]);
  });
}
