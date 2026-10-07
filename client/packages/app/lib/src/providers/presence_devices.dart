// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which kinds of client each member is connected from, as this connection is
/// told.
///
/// Kept apart from [PresenceController]'s status map so a second device
/// connecting rebuilds only the avatars that draw it. An absent id means the
/// server named no kinds, which is also what an offline or hidden member
/// reads as.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

class PresenceDevicesController
    extends StateNotifier<Map<String, Set<api.PresenceDevice>>> {
  PresenceDevicesController() : super(const {});

  /// Sets or clears one member's kinds. `PresenceController` feeds this from
  /// the live socket, so this holds no subscription of its own.
  void apply(String userId, Set<api.PresenceDevice> devices) {
    if (!mounted) return;
    final current = state[userId] ?? const <api.PresenceDevice>{};
    if (current.length == devices.length && current.containsAll(devices)) {
      return;
    }
    final next = {...state};
    if (devices.isEmpty) {
      next.remove(userId);
    } else {
      next[userId] = devices;
    }
    state = next;
  }

  /// Applies a batch lookup: every id it names is now exactly as told.
  void applyBatch(Iterable<api.PresenceStatus> statuses) {
    for (final status in statuses) {
      apply(status.userId, status.devices);
    }
  }

  /// Forgets everything, for a session ending.
  void clear() {
    if (mounted) state = const {};
  }
}

final presenceDevicesProvider =
    StateNotifierProvider<
      PresenceDevicesController,
      Map<String, Set<api.PresenceDevice>>
    >((ref) => PresenceDevicesController());

/// True only when the member is connected, and every live socket is a phone.
/// A desktop, a browser, or a client the server could not classify beside the
/// phone reads false, so the plain dot never claims "phone only" on a guess.
bool isMobileOnly(Set<api.PresenceDevice>? devices) =>
    devices != null &&
    devices.isNotEmpty &&
    devices.every((d) => d == api.PresenceDevice.mobile);

/// [isMobileOnly] for one member, scoped so other members' changes do not
/// rebuild the watcher.
final memberMobileOnlyProvider = Provider.autoDispose.family<bool, String>(
  (ref, userId) =>
      ref.watch(presenceDevicesProvider.select((m) => isMobileOnly(m[userId]))),
);
