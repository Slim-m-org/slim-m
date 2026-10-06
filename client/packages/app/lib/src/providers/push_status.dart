// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The push registration status shown on the settings screen.
library;

/// This device's push registration state, plain enough to read at a glance
/// off the settings screen rather than guessing from server logs, which is
/// exactly what a silent, un-diagnosable failure used to force.
enum PushStatus {
  /// Not signed in, so nothing has been attempted.
  notSignedIn,

  /// This platform has no push channel implemented (desktop).
  unsupportedPlatform,

  /// Signed in and supported, but no device token has arrived yet: usually
  /// waiting on the permission prompt, or the wait timed out.
  noTokenYet,

  /// The native side reported the device token request itself failed.
  registrationFailed,

  /// A token was obtained, but telling the server about it failed.
  serverError,

  /// The server has this device's current token and push public key.
  registered,

  /// The server has this device's current token and push public key, but
  /// Android's runtime notification permission is denied - so, unlike
  /// [registered], nothing this device receives will actually show. Kept
  /// distinct from [registered] rather than folded into it: the server
  /// believes this device is reachable ([FirebaseMessaging.getToken]
  /// succeeds regardless of notification permission), so without this the
  /// settings screen would say "registered" while every push is silently
  /// dropped, with no way to tell from the device itself.
  registeredNotificationsBlocked,
}

/// A plain-English label for [PushStatus], for the settings screen.
extension PushStatusLabel on PushStatus {
  String get label => switch (this) {
    PushStatus.notSignedIn => 'Not signed in',
    PushStatus.unsupportedPlatform => 'Not available on this device',
    PushStatus.noTokenYet => 'Waiting on the notification permission',
    PushStatus.registrationFailed => 'The device could not register',
    PushStatus.serverError => 'Could not reach the server',
    PushStatus.registered => 'Registered for notifications',
    PushStatus.registeredNotificationsBlocked =>
      'Registered, but notifications are blocked in system settings',
  };
}
