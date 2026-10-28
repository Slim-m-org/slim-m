// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this client is still old enough to talk to the server it is
/// pointed at (decision 0025).
///
/// The wire is additive, so an old client normally keeps working across a
/// server upgrade and this answers "fine" forever. The floor exists for the
/// case where it genuinely cannot - a client with a data-loss bug, or one
/// reading a shape the server no longer sends - and is the only thing in
/// this app allowed to stop a working session outright.
///
/// Re-read whenever the connection comes back, because that is when a server
/// upgrade actually reaches a client that was already running: Watchtower
/// replaces the container, every socket drops, and the reconnect is the
/// first moment the new `/version` can be seen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';

/// How this client stands against the server's floor.
enum ClientFloor {
  /// No floor, or this client is at or above it.
  fine,

  /// Below the floor: the server will not serve this build any more.
  tooOld,

  /// The floor could not be read - an unreachable server, a version that
  /// will not parse, a build that cannot say what version it is. Never
  /// blocks: refusing to run because a check failed would turn every flaky
  /// network into an unusable app.
  unknown,
}

/// Compares [clientVersion] against a server's [minClientVersion].
///
/// Anything unreadable on either side is [ClientFloor.unknown], and a null
/// floor is [ClientFloor.fine], because saying nothing is how every server
/// older than this field declines to gate.
ClientFloor clientFloorFor({
  required String? minClientVersion,
  required String? clientVersion,
}) {
  if (minClientVersion == null || minClientVersion.trim().isEmpty) {
    return ClientFloor.fine;
  }
  final floor = _parse(minClientVersion);
  final mine = _parse(clientVersion);
  if (floor == null || mine == null) return ClientFloor.unknown;
  for (var i = 0; i < 3; i++) {
    if (mine[i] != floor[i]) {
      return mine[i] > floor[i] ? ClientFloor.fine : ClientFloor.tooOld;
    }
  }
  return ClientFloor.fine;
}

List<int>? _parse(String? raw) {
  if (raw == null) return null;
  final parts = raw.split(RegExp('[-+]')).first.split('.');
  if (parts.length != 3) return null;
  final numbers = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null) return null;
    numbers.add(value);
  }
  return numbers;
}

/// Where this client stands right now, refreshed on every reconnect.
///
/// Resolves to [ClientFloor.unknown] while it is still asking, so nothing is
/// blocked on a pending request.
final clientFloorProvider = FutureProvider<ClientFloor>((ref) async {
  // Re-asks on reconnect: that is when the server on the other end may have changed under us.
  ref.watch(syncControllerProvider);
  if (!ref.watch(sessionProvider).isSignedIn) return ClientFloor.fine;

  final appInfo = await ref.watch(appInfoProvider.future);
  try {
    final version = await ref.watch(apiProvider).version();
    return clientFloorFor(
      minClientVersion: version.minClientVersion,
      clientVersion: appInfo.version,
    );
  } on api.ApiException catch (error, stack) {
    api.reportFailure(
      api.LogTag.ui,
      "read the server's minimum app version",
      error,
      stack,
    );
    return ClientFloor.unknown;
  } catch (error, stack) {
    api.reportFailure(
      api.LogTag.ui,
      "read the server's minimum app version",
      error,
      stack,
    );
    return ClientFloor.unknown;
  }
});
