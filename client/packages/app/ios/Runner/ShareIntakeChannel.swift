// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Flutter
import UIKit

/// The app half of the iOS share sheet; the Dart half is
/// `packages/app/lib/src/features/share/providers/share_source.dart`, which owns the channel name.
///
/// `ShareExtension/ShareIntakeWriter.swift` copies what was shared into a batch folder of the
/// App Group. This moves each finished batch into the app's caches, where Dart reads the files,
/// and tells Dart one is waiting whenever the app comes to the front.
enum ShareIntakeChannel {
  static let name = "top.npcserver.slimm/share_intake"

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "take" else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let share = takePending()
      DispatchQueue.main.async { result(share) }
    }
  }

  /// A cold start finds the share through Dart's startup `take`; a warm one through this.
  static func announceArrivals(on channel: FlutterMethodChannel) {
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      if hasPending() { channel.invokeMethod("arrived", arguments: nil) }
    }
  }

  private static var inbox: URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: ShareIntakeRules.appGroupIdentifier)?
      .appendingPathComponent(ShareIntakeRules.batchRoot)
  }

  private static var shelf: URL? {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent(ShareIntakeRules.batchRoot)
  }

  private static func batchNames(in folder: URL?) -> [String] {
    guard let folder else { return [] }
    return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  private static func hasManifest(_ batch: URL) -> Bool {
    FileManager.default.fileExists(
      atPath: batch.appendingPathComponent(ShareIntakeRules.manifestName).path)
  }

  private static func hasPending() -> Bool {
    guard let inbox else { return false }
    return batchNames(in: inbox).contains { hasManifest(inbox.appendingPathComponent($0)) }
  }

  private static func takePending() -> [String: Any]? {
    guard let inbox, let shelf else { return nil }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    purge(inbox, now: now)
    purge(shelf, now: now)
    let shares = batchNames(in: inbox).compactMap { name -> [String: Any]? in
      let batch = inbox.appendingPathComponent(name)
      return hasManifest(batch) ? adopt(batch, into: shelf.appendingPathComponent(name)) : nil
    }
    return shares.isEmpty ? nil : ShareIntakeRules.mergeShares(shares)
  }

  /// Moves a finished batch to [home] and rewrites its manifest's relative paths to absolute ones.
  private static func adopt(_ batch: URL, into home: URL) -> [String: Any]? {
    let manifest = batch.appendingPathComponent(ShareIntakeRules.manifestName)
    let fm = FileManager.default
    guard let data = try? Data(contentsOf: manifest),
      var wire = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      try? fm.removeItem(at: batch)
      return nil
    }
    let listed = wire["files"] as? [[String: Any]] ?? []
    do {
      try fm.createDirectory(at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fm.removeItem(at: home)
      try fm.moveItem(at: batch, to: home)
    } catch {
      try? fm.removeItem(at: batch)
      wire["files"] = [Any]()
      wire["unreadable"] = (wire["unreadable"] as? Int ?? 0) + listed.count
      return wire
    }
    try? fm.removeItem(at: home.appendingPathComponent(ShareIntakeRules.manifestName))
    wire["files"] = listed.compactMap { file -> [String: Any]? in
      guard let relative = file["path"] as? String else { return nil }
      var absolute = file
      absolute["path"] = home.appendingPathComponent(relative).path
      return absolute
    }
    return wire
  }

  private static func purge(_ folder: URL, now: Int64) {
    for name in batchNames(in: folder) {
      let batch = folder.appendingPathComponent(name)
      let expired = ShareIntakeRules.batchIsExpired(name, hasManifest: hasManifest(batch), nowMillis: now)
      if expired { try? FileManager.default.removeItem(at: batch) }
    }
  }
}
