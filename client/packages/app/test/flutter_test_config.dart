// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Runs once per test binary in this package, before any test in it.
///
/// It exists for one reason. drift warns when `SlimmDatabase` is constructed
/// more than once in a process, because two databases sharing one
/// `QueryExecutor` race each other. Nothing here shares one: every harness
/// builds its own `NativeDatabase.memory()`, checked across all 81
/// construction sites in this directory rather than assumed, so the warning is
/// a false positive on every suite that opens a database more than once.
///
/// It is not free noise. Each warning drags a ten-frame stack trace with it,
/// and a test that fails for a real reason has its message buried among them -
/// which is exactly when output legibility matters most.
///
/// Scoped as narrowly as the mechanism allows: one flag, one warning, tests
/// only. If a harness ever does hand two databases the same executor, this
/// hides the warning that would have said so, so the premise above is the
/// thing to re-check rather than this file.
library;

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // The real plugin has no host here, and only the snapshot render path reaches it.
  setUp(() => SharedPreferences.setMockInitialValues(const {}));
  await testMain();
}
