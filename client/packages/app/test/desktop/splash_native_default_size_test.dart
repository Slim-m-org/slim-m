// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [DesktopWindowShell.splashWindowSize] and `my_application.cc`'s
/// `gtk_window_set_default_size` are two sources of the same number, one
/// Dart and one C, with no shared constant to keep them honest at compile
/// time. This is the honest substitute: read the native default straight
/// out of the runner source and check it against the Dart constant, so a
/// change to one that forgets the other fails a test instead of silently
/// reintroducing the resize-before-map race `applyInitialGeometry`'s own
/// doc comment and decision 0012's superseding section both describe.
///
/// Reads the C file through `codeOnly` (`slimm_test_support`) before matching, the
/// same discipline every other source-reading gate in this suite already
/// applies, so a comment mentioning some other size cannot satisfy this.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';

import 'package:slimm_test_support/source_gates.dart';

final _defaultSizeCall = RegExp(
  r'gtk_window_set_default_size\(\s*window,\s*(\d+),\s*(\d+)\s*\)',
);

void main() {
  test('the Linux runner is born at DesktopWindowShell.splashWindowSize', () {
    final runner = File('linux/runner/my_application.cc');
    expect(
      runner.existsSync(),
      isTrue,
      reason: 'run this from the app package root',
    );

    final source = codeOnly(runner.readAsStringSync());
    final match = _defaultSizeCall.firstMatch(source);
    expect(
      match,
      isNotNull,
      reason: 'no gtk_window_set_default_size(window, W, H) call found',
    );

    final width = int.parse(match!.group(1)!);
    final height = int.parse(match.group(2)!);
    expect(
      width,
      DesktopWindowShell.splashWindowSize.width.toInt(),
      reason:
          'the native default width must be born at the splash size; '
          'see desktop_window_shell.dart and my_application.cc',
    );
    expect(
      height,
      DesktopWindowShell.splashWindowSize.height.toInt(),
      reason:
          'the native default height must be born at the splash size; '
          'see desktop_window_shell.dart and my_application.cc',
    );
  });
}
