// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Flutter
import UIKit

/// Hides slim-m's content from the iOS task switcher while the biometric app
/// lock is on (`AppLockWindowChannel.shieldEnabled`). The cover has to go up
/// synchronously in `sceneWillResignActive`, before that method returns: the
/// system captures its snapshot right after, and a view added later cannot
/// retroactively hide anything the snapshot already saw.
class SceneDelegate: FlutterSceneDelegate {
  private var privacyShield: UIView?
  private var fallbackRelease: DispatchWorkItem?

  /// Native backstop for a Dart side that never answers, so a missed release
  /// cannot leave the app permanently covered.
  private static let fallbackDelay: TimeInterval = 1.0

  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    fallbackRelease?.cancel()
    fallbackRelease = nil
    guard AppLockWindowChannel.shieldEnabled, let window, privacyShield == nil else { return }
    let shield = UIView(frame: window.bounds)
    shield.backgroundColor = .systemBackground
    window.addSubview(shield)
    privacyShield = shield
    AppLockWindowChannel.releaseShield = { [weak self] in self?.removeShield() }
  }

  /// The shield stays up on return: the engine resumes Dart after this method
  /// returns, so removing it here would show the last unlocked frame until
  /// the lock screen paints. Dart releases it through `releasePrivacyShield`.
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    guard privacyShield != nil else { return }
    guard AppLockWindowChannel.shieldEnabled else {
      removeShield()
      return
    }
    let work = DispatchWorkItem { [weak self] in self?.removeShield() }
    fallbackRelease?.cancel()
    fallbackRelease = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fallbackDelay, execute: work)
  }

  private func removeShield() {
    fallbackRelease?.cancel()
    fallbackRelease = nil
    privacyShield?.removeFromSuperview()
    privacyShield = nil
  }
}
