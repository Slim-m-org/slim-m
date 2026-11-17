// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What gives way when this client starts a call, such as a voice message
/// playing or being recorded; each registers itself and the join awaits them.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

class CallStartYields {
  CallStartYields({this.limit = const Duration(seconds: 3)});

  /// The longest a join waits on them, so a recorder that hangs cannot hold the call.
  final Duration limit;

  final _yields = <Future<void> Function()>{};

  /// Registers [yieldToCall]; the returned callback removes it again.
  void Function() add(Future<void> Function() yieldToCall) {
    _yields.add(yieldToCall);
    return () => _yields.remove(yieldToCall);
  }

  /// Runs every registered yield and waits for them, up to [limit].
  Future<void> callStarting() async {
    try {
      await Future.wait([for (final y in List.of(_yields)) y()]).timeout(limit);
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'Something playing or recording did not give way to the call',
        error,
        stack,
      );
    }
  }
}

final callStartYieldsProvider = Provider<CallStartYields>(
  (ref) => CallStartYields(),
);
