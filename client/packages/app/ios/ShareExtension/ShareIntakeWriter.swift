// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Foundation
import UniformTypeIdentifiers

/// Copies what the share sheet handed over into one batch folder of the App Group.
///
/// The extension's file URLs die with its process, so every file is copied before
/// the app is opened. The manifest goes in last; `Runner/ShareIntakeChannel.swift`
/// only collects batches that have one.
final class ShareIntakeWriter {
  private let batch: URL
  private var files: [[String: Any]] = []
  private var texts: [String] = []
  private var unreadable = 0
  private var tooLarge = 0
  private var copiedBytes: Int64 = 0

  init?(now: Date = Date()) {
    guard
      let group = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: ShareIntakeRules.appGroupIdentifier)
    else { return nil }
    let name = ShareIntakeRules.batchName(
      nowMillis: Int64(now.timeIntervalSince1970 * 1000), unique: UUID().uuidString)
    batch = group.appendingPathComponent(ShareIntakeRules.batchRoot).appendingPathComponent(name)
  }

  /// Handles the providers one after another, then calls [completion] with whether a batch was written.
  func run(_ providers: [NSItemProvider], completion: @escaping (Bool) -> Void) {
    do {
      try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
    } catch {
      completion(false)
      return
    }
    next(providers, at: 0) { [self] in completion(finish()) }
  }

  private func next(_ providers: [NSItemProvider], at index: Int, done: @escaping () -> Void) {
    guard index < providers.count else {
      done()
      return
    }
    handle(providers[index], index: index) { [self] in
      next(providers, at: index + 1, done: done)
    }
  }

  private func handle(_ provider: NSItemProvider, index: Int, done: @escaping () -> Void) {
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [self] item, _ in
        if let url = fileURL(from: item) {
          copyScoped(url, index: index)
        } else {
          unreadable += 1
        }
        done()
      }
    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [self] item, _ in
        if let url = item as? URL {
          addText(url.absoluteString)
        } else {
          unreadable += 1
        }
        done()
      }
    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [self] item, _ in
        if let text = item as? String {
          addText(text)
        } else {
          unreadable += 1
        }
        done()
      }
    } else if let type = provider.registeredTypeIdentifiers.first(where: {
      UTType($0)?.conforms(to: .data) == true
    }) {
      provider.loadFileRepresentation(forTypeIdentifier: type) { [self] url, _ in
        if let url {
          copy(url, index: index, fallbackType: UTType(type))
        } else {
          unreadable += 1
        }
        done()
      }
    } else {
      unreadable += 1
      done()
    }
  }

  private func fileURL(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
    return nil
  }

  private func addText(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, !texts.contains(trimmed) { texts.append(trimmed) }
  }

  private func copyScoped(_ url: URL, index: Int) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    copy(url, index: index, fallbackType: nil)
  }

  private func copy(_ source: URL, index: Int, fallbackType: UTType?) {
    let room = ShareIntakeRules.allowedBytes(copiedSoFar: copiedBytes)
    let declared = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) } ?? 0
    if declared > room {
      tooLarge += 1
      return
    }
    let name = ShareIntakeRules.capNameBytes(ShareIntakeRules.safeFileName(source.lastPathComponent))
    let folder = batch.appendingPathComponent(String(index))
    let target = folder.appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: target)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      unreadable += 1
      return
    }
    let length = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) } ?? declared
    if length > room {
      try? FileManager.default.removeItem(at: folder)
      tooLarge += 1
      return
    }
    copiedBytes += length
    let mime =
      UTType(filenameExtension: target.pathExtension)?.preferredMIMEType
      ?? fallbackType?.preferredMIMEType
    files.append([
      "path": "\(index)/\(name)",
      "name": name,
      "mimeType": mime ?? NSNull(),
      "length": length,
    ])
  }

  /// Writes the manifest, or removes the folder when there is nothing to hand over.
  private func finish() -> Bool {
    let text = texts.joined(separator: "\n")
    if files.isEmpty && text.isEmpty && unreadable == 0 && tooLarge == 0 {
      try? FileManager.default.removeItem(at: batch)
      return false
    }
    let wire: [String: Any] = [
      "files": files,
      "text": text.isEmpty ? NSNull() : text,
      "unreadable": unreadable,
      "tooLarge": tooLarge,
    ]
    do {
      let data = try JSONSerialization.data(withJSONObject: wire)
      try data.write(
        to: batch.appendingPathComponent(ShareIntakeRules.manifestName), options: .atomic)
      return true
    } catch {
      try? FileManager.default.removeItem(at: batch)
      return false
    }
  }
}
