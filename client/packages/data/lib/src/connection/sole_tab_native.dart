// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

/// A native process owns its database file alone; recovery refuses a second.
Future<bool> claimSoleTab() async => true;
