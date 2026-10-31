// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sync controllers for tests that need the shell without a live socket.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

/// Never connects; [report] moves the status by hand.
class NoopSyncController extends SyncController {
  NoopSyncController(super.ref);

  @override
  Future<void> start() async {}

  void report(SyncStatus status) => state = status;
}

/// Starts in [status] and never connects.
class StubSyncController extends NoopSyncController {
  StubSyncController(super.ref, [SyncStatus status = SyncStatus.live]) {
    state = status;
  }
}

/// Reports [status] (live by default) once started, without opening a socket.
class LiveSyncController extends SyncController {
  LiveSyncController(super.ref, [this.status = SyncStatus.live]);

  final SyncStatus status;

  /// How many times a start was asked for.
  int startCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
    state = status;
  }
}

/// Stands in for a session that has already caught up once, without a socket.
///
/// The flag is set past a real `await`, or Riverpod refuses the write as a
/// provider modifying another during initialization.
class CaughtUpSyncController extends SyncController {
  CaughtUpSyncController(this._testRef) : super(_testRef);

  final Ref _testRef;

  @override
  Future<void> start() async {
    await Future<void>.value();
    _testRef.read(initialSyncCompleteProvider.notifier).state = true;
  }
}
