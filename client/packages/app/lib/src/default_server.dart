// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one server this build knows about without being told.
///
/// Compiled in rather than typed, so joining it can skip the address prompt:
/// the binary and the address are already the same trust decision.
library;

/// The official instance. Someone with no invite and no server of their own
/// still needs somewhere to land.
const officialServer = 'https://slim.npc-server.top';

/// Whether [address] is the compiled-in official server, compared by origin
/// so a trailing slash or an explicit default port cannot dodge the check.
bool isOfficialServer(Uri address) =>
    address.origin == Uri.parse(officialServer).origin;
