// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_APP_IDENTITY_H_
#define RUNNER_APP_IDENTITY_H_

/// Gives this process slim-m's AppUserModelID (shortcut_identity.h). Windows
/// reads it when a window is created, so this runs before any window exists.
void ClaimAppIdentity();

/// Gives the Start menu, desktop and taskbar shortcuts into the per-user layout
/// the same AppUserModelID, and points a pin of an older version's app at the
/// launcher, so an update never splits a pin from the running window. Needs COM.
void RepairShortcuts();

#endif  // RUNNER_APP_IDENTITY_H_
