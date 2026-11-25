// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Flutter
import Foundation

/// The app half of the biometric app lock's privacy shield; the Dart half is
/// `packages/platform/lib/src/app_lock_window_channel.dart`, which owns the
/// channel name.
///
/// `SceneDelegate` reads `shieldEnabled` synchronously from
/// `sceneWillResignActive`, not through a fresh channel call: the system
/// captures its task-switcher snapshot immediately after that method
/// returns, and an async round trip to Dart would race it and lose.
enum AppLockWindowChannel {
  static let name = "top.npcserver.slimm/app_lock_window"

  /// Mirrors the Dart-side app-lock preference. Written every time Dart
  /// calls `setPrivacyShield`, including once during bootstrap, so a resume
  /// can never race the preference's own restore.
  private(set) static var shieldEnabled = false

  /// Set by `SceneDelegate` while its shield is up; Dart calls it through
  /// `releasePrivacyShield` once the lock screen or the app has painted.
  static var releaseShield: (() -> Void)?

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setPrivacyShield":
      shieldEnabled = (call.arguments as? Bool) ?? false
      result(nil)
    case "releasePrivacyShield":
      releaseShield?()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
