// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The space-wide screen-share height limit a share starts under.
library;

import 'package:slimm_api/api.dart' show LogTag, SlimmApi, reportFailure;

/// From the unauthenticated `GET /version`, or null on failure or an older server.
/// It is a courtesy cap, not a boundary, so an unreachable Space fails open and the share starts at the chosen quality.
Future<int?> screenShareCeilingFrom(SlimmApi api) async {
  try {
    final version = await api.version();
    return version.screenShareMaxHeight;
  } catch (error, stack) {
    reportFailure(
      LogTag.voice,
      "read the server's screen share quality limit",
      error,
      stack,
    );
    return null;
  }
}
