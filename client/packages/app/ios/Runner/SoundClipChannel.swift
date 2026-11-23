// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import AVFoundation
import Flutter

/// The app half of soundboard clips heard during a call on iPhone; the Dart half is
/// `lib/src/audio/call_path_clip_output.dart`, which owns the channel name.
///
/// Each clip is an `AVAudioPlayerNode` on its own engine, mixed into whatever the call's audio
/// session is already doing. Nothing here sets the session's category, mode or activation:
/// audioplayers resets the category on every play and deactivates the session when the clip ends.
enum SoundClipChannel {
  static let name = "top.npcserver.slimm/sound_clip"
  private static let player = SoundClipPlayer()

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "play" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    guard let bytes = args["bytes"] as? FlutterStandardTypedData else {
      result(FlutterError(code: "bad_args", message: "bytes is required", details: nil))
      return
    }
    do {
      try player.play(
        data: bytes.data,
        fileExtension: args["extension"] as? String ?? "mp3",
        volume: Float(args["volume"] as? Double ?? 0.6))
      result(nil)
    } catch {
      result(FlutterError(code: "play_failed", message: "\(error)", details: nil))
    }
  }
}

/// One-shot clips that overlap the way voices do. Everything runs on the main queue.
final class SoundClipPlayer {
  private final class Voice {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let url: URL
    init(url: URL) { self.url = url }
  }

  struct NoCallSession: Error {}
  struct TooManyClips: Error {}

  /// More than a call ever needs at once; a flood of presses must not pile up engines.
  static let maxVoices = 8

  private var voices: [UUID: Voice] = [:]

  /// Reads the session's category and never writes it: with no call up there is nothing safe to join.
  func play(data: Data, fileExtension: String, volume: Float) throws {
    guard AVAudioSession.sharedInstance().category == .playAndRecord else {
      throw NoCallSession()
    }
    guard voices.count < SoundClipPlayer.maxVoices else { throw TooManyClips() }
    let id = UUID()
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("slimm-clip-\(id.uuidString).\(fileExtension)")
    try data.write(to: url)
    let voice = Voice(url: url)
    voices[id] = voice
    do {
      let file = try AVAudioFile(forReading: url)
      voice.engine.attach(voice.node)
      voice.engine.connect(voice.node, to: voice.engine.mainMixerNode, format: file.processingFormat)
      voice.node.volume = volume
      try voice.engine.start()
      voice.node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) {
        [weak self] _ in
        DispatchQueue.main.async { self?.finish(id) }
      }
      voice.node.play()
    } catch {
      finish(id)
      throw error
    }
  }

  private func finish(_ id: UUID) {
    guard let voice = voices.removeValue(forKey: id) else { return }
    voice.node.stop()
    if voice.engine.isRunning { voice.engine.stop() }
    voice.engine.detach(voice.node)
    try? FileManager.default.removeItem(at: voice.url)
  }
}
