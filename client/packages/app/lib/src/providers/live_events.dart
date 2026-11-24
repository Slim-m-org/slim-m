// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Exposes every live server event to whichever feature wants to react to
/// one: presence, typing, reactions, pins, and polls all listen here rather
/// than each opening its own connection or teaching [SyncController] about
/// their concerns.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import 'sync_controller.dart';

/// A broadcast stream of every event the live socket delivers, for the
/// current session. Watching this never itself opens or closes the
/// connection: [SyncController] owns that lifecycle regardless of who else
/// is listening.
final liveEventsProvider = Provider<Stream<ServerEvent>>(
  (ref) => ref.watch(syncControllerProvider.notifier).liveEvents,
);

/// The messages each reconnect's catch-up stored, which the live socket never delivered.
final caughtUpMessagesProvider = Provider<Stream<List<Message>>>(
  (ref) => ref.watch(syncControllerProvider.notifier).caughtUpMessages,
);
