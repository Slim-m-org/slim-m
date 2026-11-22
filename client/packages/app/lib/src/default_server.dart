// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one server this build knows about without being told.
///
/// Compiled in rather than typed, so joining it can skip the address prompt:
/// the binary and the address are already the same trust decision.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

/// The official instance. Someone with no invite and no server of their own
/// still needs somewhere to land.
const officialServer = 'https://slim.npc-server.top';

/// Where Firebase Test Lab devices land instead: Google's automated runs tap
/// "Join the official Space" and must never create accounts or ring members on
/// the real instance.
const reviewServer = 'https://slim-review.npc-server.top';

/// The address "the official Space" means on this device, resolved once at
/// startup; the compiled-in [officialServer] when the check is false or fails.
Future<Uri> resolveOfficialServer({TestLabChannel? testLab}) async {
  final isTestLab = await (testLab ?? TestLabChannel()).isTestLabDevice();
  return Uri.parse(isTestLab ? reviewServer : officialServer);
}

/// The resolved official address; see [resolveOfficialServer].
final officialServerProvider = Provider<Uri>(
  (ref) => Uri.parse(officialServer),
);

/// Whether [address] is the [official] server, compared by origin so a
/// trailing slash or an explicit default port cannot dodge the check.
bool isOfficialServer(Uri address, Uri official) =>
    address.origin == official.origin;
