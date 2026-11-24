// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How long a poller waits on one native read before giving up on it.
library;

/// A read past this counts as a failure, so an overlap guard always releases.
const Duration kPollReadTimeout = Duration(seconds: 5);
