// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Flutter
import UIKit
import UserNotifications

/// The app half of the icon badge; the Dart half is
/// `packages/platform/lib/src/app_badge_channel.dart`, which owns the channel
/// name. The notification service extension sets the badge when a push
/// arrives (`NotificationService/BadgeCount.swift`); this makes it right again
/// whenever the app knows better.
enum AppBadgeChannel {
  static let name = "top.npcserver.slimm/app_badge"

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "badgesAllowed" {
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        result(settings.badgeSetting != .disabled)
      }
      return
    }
    if call.method == "clearDelivered" {
      let args = call.arguments as? [String: Any]
      clearDelivered(
        channelIds: Set(args?["channelIds"] as? [String] ?? []),
        all: args?["all"] as? Bool ?? false)
      result(nil)
      return
    }
    guard call.method == "sync", let args = call.arguments as? [String: Any],
      let count = args["count"] as? Int
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    let readChannelIds = args["readChannelIds"] as? [String] ?? []
    sync(count: max(count, 0), readChannelIds: Set(readChannelIds))
    result(nil)
  }

  /// A silent `read` push: the sealed envelope names a channel read on another device, so this
  /// one takes that channel's delivered notifications down and sets the badge to what is left.
  /// Anything that does not open as a fresh `read` is ignored, and `completion` always runs.
  static func applyReadPush(_ userInfo: [AnyHashable: Any], completion: @escaping () -> Void) {
    guard let channelId = readChannelId(in: userInfo) else {
      completion()
      return
    }
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { delivered in
      let ours = delivered.filter { $0.request.content.threadIdentifier == channelId }
      if !ours.isEmpty {
        center.removeDeliveredNotifications(withIdentifiers: ours.map { $0.request.identifier })
      }
      setBadge(
        BadgeCount.afterRead(
          channelId: channelId,
          deliveredThreads: delivered.map { $0.request.content.threadIdentifier }))
      completion()
    }
  }

  private static func readChannelId(in userInfo: [AnyHashable: Any]) -> String? {
    guard let encoded = userInfo["payload"] as? String,
      let sealed = Data(base64Encoded: encoded),
      let privateKey = PushKeychain.privateKey(),
      let plaintext = PushSealedBox.open([UInt8](sealed), privateKey: privateKey),
      let envelope = PushEnvelope.decode(plaintext),
      envelope.kind == "read", !envelope.isStale(),
      let channelId = envelope.channelId, !channelId.isEmpty
    else { return nil }
    return channelId
  }

  private static func setBadge(_ count: Int) {
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    } else {
      DispatchQueue.main.async { UIApplication.shared.applicationIconBadgeNumber = count }
    }
  }

  /// Sets the badge and drops delivered notifications of channels that are
  /// read, so the extension's next count starts from what is really unread.
  private static func sync(count: Int, readChannelIds: Set<String>) {
    let center = UNUserNotificationCenter.current()
    setBadge(count)
    center.getDeliveredNotifications { delivered in
      let stale = delivered.filter { readChannelIds.contains($0.request.content.threadIdentifier) }
      if !stale.isEmpty {
        center.removeDeliveredNotifications(withIdentifiers: stale.map { $0.request.identifier })
      }
    }
  }

  /// Removes the banners of a signed-out account, so the next person holding
  /// the phone does not read them; every banner when no account remains.
  private static func clearDelivered(channelIds: Set<String>, all: Bool) {
    let center = UNUserNotificationCenter.current()
    if all {
      center.removeAllDeliveredNotifications()
      return
    }
    center.getDeliveredNotifications { delivered in
      let ours = delivered.filter { channelIds.contains($0.request.content.threadIdentifier) }
      if !ours.isEmpty {
        center.removeDeliveredNotifications(withIdentifiers: ours.map { $0.request.identifier })
      }
    }
  }
}
