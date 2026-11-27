// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Foundation

/// What the share intake accepts and how the extension and the app agree on a batch.
///
/// Compiled into the extension, the app and the unit tests. The Android twin is
/// `ShareIntakeRules.kt`; the batch the extension writes carries the same fields
/// `IncomingShare.fromWire` reads on the Dart side.
enum ShareIntakeRules {
  /// Must match `com.apple.security.application-groups` in both entitlements files.
  static let appGroupIdentifier = "group.top.npcserver.slimm"

  /// The folder, in the group container and in the app's caches, that holds one folder per share.
  static let batchRoot = "shared_intake"

  /// Written last, atomically: a batch folder without it is a copy still in progress.
  static let manifestName = "ready.json"

  /// Opens the app from the extension; must be a scheme in the app's `CFBundleURLTypes`.
  static let openURLString = "slimm-share://intake"

  static let maxNameBytes = 200
  private static let maxExtensionChars = 16

  /// One shared file past this is refused rather than copied; the server's own limit is checked later.
  static let maxFileBytes: Int64 = 2 * 1024 * 1024 * 1024

  /// One share past this in total stops copying, so a batch cannot fill the phone.
  static let maxShareBytes: Int64 = 4 * 1024 * 1024 * 1024

  /// A copy nobody collected is dropped after this, the same day Android keeps one.
  static let keepMillis: Int64 = 24 * 60 * 60 * 1000

  /// An extension that died mid-copy leaves a folder with no manifest; it goes after this.
  static let unfinishedMillis: Int64 = 60 * 60 * 1000

  /// How many more bytes one file may take: the per-file cap and what is left of the share.
  static func allowedBytes(copiedSoFar: Int64) -> Int64 {
    max(0, min(maxFileBytes, maxShareBytes - copiedSoFar))
  }

  /// A folder name that carries its own age, so no file timestamp has to be read.
  static func batchName(nowMillis: Int64, unique: String) -> String {
    "\(nowMillis)-\(unique)"
  }

  static func batchMillis(_ name: String) -> Int64? {
    guard let head = name.split(separator: "-", maxSplits: 1).first else { return nil }
    return Int64(head)
  }

  /// A folder whose name does not parse is never kept: nothing wrote it but this code.
  static func batchIsExpired(_ name: String, hasManifest: Bool, nowMillis: Int64) -> Bool {
    guard let made = batchMillis(name) else { return true }
    return nowMillis - made > (hasManifest ? keepMillis : unfinishedMillis)
  }

  /// Keeps a sender-chosen name from escaping its folder.
  static func safeFileName(_ raw: String) -> String {
    let last = raw.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? raw
    let scrubbed = last.unicodeScalars.map { scalar -> Character in
      scalar.value < 0x20 || scalar == "\\" ? "_" : Character(scalar)
    }
    let cleaned = String(scrubbed).trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "shared" : cleaned
  }

  /// Shortens [name] to `maxNameBytes` of UTF-8 by cutting its stem, keeping the extension and whole characters.
  static func capNameBytes(_ name: String) -> String {
    if name.utf8.count <= maxNameBytes { return name }
    var suffix = ""
    if let dot = name.lastIndex(of: "."), dot != name.startIndex {
      let tail = String(name[dot...])
      if tail.count <= maxExtensionChars { suffix = tail }
    }
    let stem = String(name.dropLast(suffix.count))
    return takeBytes(stem, limit: maxNameBytes - suffix.utf8.count) + suffix
  }

  private static func takeBytes(_ text: String, limit: Int) -> String {
    var bytes = 0
    var kept = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      let size = String(scalar).utf8.count
      if bytes + size > limit { break }
      bytes += size
      kept.append(scalar)
    }
    return String(kept)
  }

  /// Folds shares that arrived before the first was taken into one, so none is dropped.
  static func mergeShares(_ shares: [[String: Any]]) -> [String: Any] {
    let files = shares.flatMap { $0["files"] as? [Any] ?? [] }
    let text = shares.compactMap { $0["text"] as? String }.joined(separator: "\n")
    return [
      "files": files,
      "text": text.isEmpty ? NSNull() : text,
      "unreadable": shares.reduce(0) { $0 + ($1["unreadable"] as? Int ?? 0) },
      "tooLarge": shares.reduce(0) { $0 + ($1["tooLarge"] as? Int ?? 0) },
    ]
  }
}
