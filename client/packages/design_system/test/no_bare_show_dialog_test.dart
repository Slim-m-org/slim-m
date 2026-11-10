// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Flutter's `showDialog`, `showAdaptiveDialog`, `showTimePicker`,
/// `showDatePicker` and `showDateRangePicker` all go through `showRawDialog`,
/// which opens a native OS window when the `windowing` flag is on (the Linux
/// build). The only sanctioned entry points are `showInWindowDialog` and
/// `showAppTimePicker` in `in_window_dialog.dart`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slimm_test_support/source_gates.dart';

final _windowedCalls = RegExp(
  r'(?<![\w.])(showDialog|showAdaptiveDialog|showTimePicker|showDatePicker|'
  r'showDateRangePicker|showCupertinoDialog)\s*(<[^>(]*>)?\s*\(',
);

void main() {
  test('no package calls a Flutter helper that can open an OS window', () {
    final packages = Directory('..');
    expect(Directory('lib').existsSync(), isTrue,
        reason: 'run from the package root');
    final offenders = <String>[];
    for (final pkg in packages.listSync().whereType<Directory>()) {
      final lib = Directory('${pkg.path}/lib');
      if (!lib.existsSync()) continue;
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        if (file.path.endsWith('in_window_dialog.dart')) continue;
        final source = codeOnly(file.readAsStringSync());
        for (final m in _windowedCalls.allMatches(source)) {
          offenders.add('${file.path}: ${m.group(1)}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'use showInWindowDialog / showAppSheet / showAppTimePicker:\n'
          '${offenders.join('\n')}',
    );
  });

  test('the gate pattern catches the calls it exists for', () {
    for (final bad in [
      'showDialog(context: c)',
      'showDialog<void>(',
      'await showTimePicker (context: c)',
      'return showDatePicker(',
    ]) {
      expect(_windowedCalls.hasMatch(codeOnly(bad)), isTrue, reason: bad);
    }
    for (final fine in [
      'showInWindowDialog<T>(',
      'showAppTimePicker(',
      '// showDialog(x)',
      "'showDialog('",
      'widget.showDialog(',
    ]) {
      expect(_windowedCalls.hasMatch(codeOnly(fine)), isFalse, reason: fine);
    }
  });
}
