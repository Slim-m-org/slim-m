// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Flutter
import Foundation

/// The app half of the screen share bridge; the Dart half is
/// `packages/rtc/lib/src/broadcast_bridge.dart`, which owns the channel name.
///
/// Two questions Dart cannot answer for itself. Whether this build can
/// broadcast at all, which needs the main bundle's Info.plist and a probe of
/// the App Group container. And how to stop a running broadcast, which no
/// public livekit_client API exposes: `BroadcastManager` is not exported from
/// `livekit_client.dart` in 2.8.1, so the notification is posted here instead.
enum BroadcastChannel {
  static let name = "top.npcserver.slimm/broadcast"

  /// Posted to the broadcast extension process. The name is livekit_client's,
  /// matched by `BroadcastExtension/DarwinNotificationCenter.swift`.
  private static let requestStopNotification = "iOS_BroadcastRequestStop"

  private static let extensionKey = "RTCScreenSharingExtension"
  private static let appGroupKey = "RTCAppGroupIdentifier"

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(isAvailable())
    case "extensionSilenceMs":
      observeHeartbeat()
      result(extensionSilenceMs())
    case "requestStop":
      requestStop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static let heartbeatNotification = "top.npcserver.slimm.BroadcastHeartbeat"
  private static var lastHeartbeat: CFAbsoluteTime?
  private static var observingHeartbeat = false

  /// Milliseconds since the extension last said it was alive, or nil if it never has.
  private static func extensionSilenceMs() -> Int? {
    guard let last = lastHeartbeat else { return nil }
    return Int((CFAbsoluteTimeGetCurrent() - last) * 1000)
  }

  private static func observeHeartbeat() {
    guard !observingHeartbeat else { return }
    observingHeartbeat = true
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      nil,
      { _, _, _, _, _ in BroadcastChannel.lastHeartbeat = CFAbsoluteTimeGetCurrent() },
      heartbeatNotification as CFString,
      nil,
      .deliverImmediately
    )
  }

  /// The container probe is the load-bearing half. Both Info.plist keys can be
  /// present and correct while the entitlement is missing from the signed
  /// build or the profile does not grant the group, and in that case capture
  /// fails silently: the broadcast starts and delivers no frames.
  private static func isAvailable() -> Bool {
    let info = Bundle.main.infoDictionary
    guard let extensionId = info?[extensionKey] as? String, !extensionId.isEmpty,
      let appGroupId = info?[appGroupKey] as? String, !appGroupId.isEmpty
    else {
      return false
    }
    return FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) != nil
  }

  private static func requestStop() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(rawValue: requestStopNotification as CFString),
      nil,
      nil,
      true
    )
  }
}
