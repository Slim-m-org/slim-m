// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which devices the list files under "Not used recently".
library;

import 'package:slimm_api/api.dart' as api;

/// How long a device may go unseen before the list files it away.
///
/// The server already drops a session whose refresh token expired (30 days);
/// this is the shorter window for one that still could sign in but has not.
const staleDeviceWindow = Duration(days: 7);

/// The devices in [list] not seen within [staleDeviceWindow] of [now].
///
/// This device is never stale, and a device the server has no last-seen time
/// for is: that is an older sign-in nothing has used since.
List<api.Device> staleDevices(List<api.Device> list, DateTime now) {
  final cutoff = now.subtract(staleDeviceWindow).millisecondsSinceEpoch;
  return [
    for (final device in list)
      if (!device.isCurrent && (device.lastSeenAt ?? 0) < cutoff) device,
  ];
}
