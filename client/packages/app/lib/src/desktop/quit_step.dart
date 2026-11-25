// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One step of a quit, isolated so its failure never keeps the window open.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Runs [step], giving up on it after [timeout] and logging any failure as "Could not [what] on quit".
Future<void> runQuitStep(
  String what,
  Duration timeout,
  Future<void> Function() step,
) async {
  try {
    await step().timeout(timeout);
  } catch (error, stack) {
    AppLog.warning(
      LogTag.platform,
      'Could not $what on quit',
      error: error,
      stack: stack,
    );
  }
}
