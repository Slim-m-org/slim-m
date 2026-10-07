// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A dnf or polkit prompt that never returns must not hold the splash forever.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/rpm_updater.dart';

void main() {
  testWidgets('a dnf that never returns still lets apply() give up', (
    tester,
  ) async {
    final hung = Completer<ProcessResult>();
    Future<ProcessResult> runner(String exe, List<String> args) {
      // dnf stuck on the transaction lock
      if (exe == 'pkexec') return hung.future;
      if (exe == 'rpm') return Future.value(ProcessResult(0, 0, '0.74.0', ''));
      return Future.value(ProcessResult(0, 0, coprRepoId, ''));
    }

    RpmUpdateResult? result;
    unawaited(
      RpmUpdater(
        run: runner,
      ).apply(currentVersion: '0.74.0').then((r) => result = r),
    );
    await tester.pump(const Duration(hours: 2));
    expect(result, isNotNull, reason: 'apply() still pending after 2 hours');
    expect(result!.ok, isFalse);
  });
}
