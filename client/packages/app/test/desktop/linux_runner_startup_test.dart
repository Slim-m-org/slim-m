// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Linux runner shows its window even when Flutter never paints, and a failed
/// registration never activates an application whose startup did not run.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_test_support/source_gates.dart';

void main() {
  final source = codeOnly(
    File('linux/runner/my_application.cc').readAsStringSync(),
  );

  test('a watchdog shows the window when no first frame arrives', () {
    expect(source, contains('g_timeout_add_seconds('));
    expect(source, contains('first_frame_watchdog_cb'));
    final watchdog = source.substring(
      source.indexOf('first_frame_watchdog_cb(gpointer'),
    );
    expect(
      watchdog.substring(0, watchdog.indexOf('}')),
      contains('gtk_widget_show'),
    );
  });

  test('the first frame cancels the watchdog', () {
    final start = source.indexOf('static void first_frame_cb');
    final body = source.substring(start, source.indexOf('}', start));
    expect(body, contains('g_source_remove'));
  });

  test('a failed registration exits instead of activating', () {
    final start = source.indexOf('g_application_register(');
    final branch = source.substring(
      start,
      source.indexOf('return TRUE;', start),
    );
    expect(branch, isNot(contains('my_application_activate')));
    expect(branch, contains('*exit_status = 1'));
  });
}
