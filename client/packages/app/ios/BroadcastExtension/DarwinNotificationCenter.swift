// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// Adapted from the LiveKit Flutter example's broadcast extension.
import Foundation

/// The notification names this process and the app share.
///
/// The first three are defined by livekit_client's iOS plugin, not by us: see
/// `DarwinNotification` in `livekit_client/ios/Classes/DarwinNotificationCenter.swift`.
/// Renaming one here silently detaches the app from the broadcast. The heartbeat
/// is ours, and only tells the app the extension process is still alive.
enum DarwinNotification: String {
  case broadcastStarted = "iOS_BroadcastStarted"
  case broadcastStopped = "iOS_BroadcastStopped"
  case broadcastRequestStop = "iOS_BroadcastRequestStop"
  case broadcastHeartbeat = "top.npcserver.slimm.BroadcastHeartbeat"
}

/// Darwin notifications are the only IPC that reaches a broadcast extension
/// from the app; they carry no payload, which is all this needs.
final class DarwinNotificationCenter {
  static let shared = DarwinNotificationCenter()

  private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()

  func postNotification(_ name: DarwinNotification) {
    CFNotificationCenterPostNotification(
      notificationCenter,
      CFNotificationName(rawValue: name.rawValue as CFString),
      nil,
      nil,
      true
    )
  }

  /// Calls `handler` on every post of `name` until `removeObserver` is called.
  /// `observer` is an opaque identity token, not retained by the system.
  func addObserver(
    _ observer: UnsafeRawPointer,
    for name: DarwinNotification,
    callback: @escaping CFNotificationCallback
  ) {
    CFNotificationCenterAddObserver(
      notificationCenter,
      observer,
      callback,
      name.rawValue as CFString,
      nil,
      .deliverImmediately
    )
  }

  func removeObserver(_ observer: UnsafeRawPointer, for name: DarwinNotification) {
    CFNotificationCenterRemoveObserver(
      notificationCenter,
      observer,
      CFNotificationName(name.rawValue as CFString),
      nil
    )
  }
}
