// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sync controllers for tests that need the shell without a live socket.
library;

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

/// Reports [SyncStatus.live] once started, without opening a socket.
class LiveSyncController extends SyncController {
  LiveSyncController(super.ref);

  @override
  Future<void> start() async {
    state = SyncStatus.live;
  }
}
