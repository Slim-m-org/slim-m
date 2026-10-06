// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bridges `local_auth`, which asks the OS to confirm the device owner -
/// Face ID, Touch ID, a fingerprint, Windows Hello, or a fallback to the
/// device passcode/PIN/pattern. This can only ever unlock a session slim-m
/// already holds; the server has no concept of a face or a fingerprint, so
/// there is no "biometric login" anywhere in this file. See
/// `app/lib/src/providers/app_lock_controller.dart` for the one caller.
///
/// `local_auth` ships no Linux implementation at all, and none for the web
/// either, so [supportsBiometricLock] is what the settings toggle and the
/// app lock controller both check before this class is ever touched.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:local_auth/local_auth.dart';

import 'host_platform.dart';

/// True on every host `local_auth` actually implements: iOS, Android, macOS
/// and Windows. False on Linux (no plugin implementation at all) and the web
/// (no browser API this could call).
bool get supportsBiometricLock => !kIsWeb && !isLinuxHost;

/// What asking the platform to confirm the device owner came back with.
enum BiometricAuthResult {
  /// The platform confirmed it was really the device owner.
  success,

  /// The check ran and did not pass - a wrong fingerprint, a cancelled
  /// prompt, a temporary lockout after too many attempts. Worth another try.
  failure,

  /// This device has neither biometrics nor a passcode/PIN/pattern set up at
  /// all, so there is nothing to check against. The one outcome the app lock
  /// controller must never leave someone stuck behind.
  unavailable,
}

/// Whether the device can check an owner at all, which is a different question
/// from whether asking the platform worked.
enum BiometricSupport {
  /// Biometrics or a device passcode can confirm the owner.
  supported,

  /// The platform answered that nothing can check an owner. The only answer
  /// the app lock may fail open on.
  unsupported,

  /// The question itself failed (a channel or plugin error), so nothing is
  /// known. Treated like a failed attempt, never like [unsupported].
  error,
}

/// The seam onto `local_auth`'s [LocalAuthentication]. A provider, like
/// `ApnsTokenChannel` and `FcmTokenChannel`, so a test can substitute a fake
/// that needs no real biometric hardware or platform channel behind it.
class BiometricAuthChannel {
  BiometricAuthChannel({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// Whether this device can check an owner at all right now, biometrics or
  /// device-passcode fallback. [BiometricSupport.unsupported] is the true
  /// "nothing to lock behind" case; callers must fail open on it rather than
  /// trap someone who enabled the lock before unenrolling every biometric and
  /// clearing their passcode, and on nothing else.
  Future<BiometricSupport> checkSupport() async {
    try {
      return await _auth.isDeviceSupported()
          ? BiometricSupport.supported
          : BiometricSupport.unsupported;
    } catch (_) {
      return BiometricSupport.error;
    }
  }

  /// Prompts biometrics first, falling back to the device passcode/PIN/pattern
  /// automatically when biometrics fail or are not enrolled - the same
  /// fallback iOS and Android already show on their own lock screens, not
  /// something this app builds itself.
  /// [LocalAuthExceptionCode.noCredentialsSet] is the only code that means
  /// there is truly nothing to check against; every other code (a cancel, a
  /// timeout, a temporary lockout, stale hardware) is a reason to let the
  /// same prompt be tried again.
  Future<BiometricAuthResult> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(localizedReason: reason);
      return ok ? BiometricAuthResult.success : BiometricAuthResult.failure;
    } on LocalAuthException catch (e) {
      return e.code == LocalAuthExceptionCode.noCredentialsSet
          ? BiometricAuthResult.unavailable
          : BiometricAuthResult.failure;
    } catch (_) {
      return BiometricAuthResult.failure;
    }
  }
}
