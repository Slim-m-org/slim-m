// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import AVFoundation
import Flutter

/// The app half of hold music on iPhone; the Dart half is
/// `lib/src/audio/call_path_hold_output.dart`, which owns the channel name.
///
/// The loop is an `AVAudioPlayerNode` on its own engine, mixed into whatever
/// the call's audio session is already doing. Nothing here sets the session's
/// category, mode or activation: the call owns the session, and the plugin
/// that used to play this (audioplayers) reset its category on every play and
/// deactivated it when the loop stopped, which cut the call's audio.
enum HoldMusicChannel {
  static let name = "top.npcserver.slimm/hold_music"
  private static let player = HoldMusicPlayer()

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "assetPath":
      let key = FlutterDartProject.lookupKey(forAsset: args["asset"] as? String ?? "")
      result(Bundle.main.path(forResource: key, ofType: nil))
    case "play":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        return
      }
      do {
        let duration = try player.play(path: path, volume: Float(args["volume"] as? Double ?? 0.2))
        result(duration)
      } catch {
        result(FlutterError(code: "play_failed", message: "\(error)", details: nil))
      }
    case "stop":
      player.stop()
      result(nil)
    case "pause":
      player.pause()
      result(nil)
    case "resume":
      player.resume()
      result(nil)
    case "setVolume":
      player.setVolume(Float(args["volume"] as? Double ?? 0.2))
      result(nil)
    case "seek":
      player.seek(seconds: args["seconds"] as? Double ?? 0)
      result(nil)
    case "position":
      result(player.positionSeconds)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// A looping file on a private engine. Everything runs on the main queue.
final class HoldMusicPlayer {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private var file: AVAudioFile?
  private var volume: Float = 0.2
  private var paused = false

  /// Bumped on every stop and seek so a loop completion from the old schedule cannot queue more audio.
  private var generation = 0

  /// Frame of the file the current schedule started from, for the position readout.
  private var startFrame: AVAudioFramePosition = 0
  private var observer: NSObjectProtocol?

  struct NoCallSession: Error {}

  /// Returns the file's length in seconds. Reads the session's category and
  /// never writes it: with no call up there is nothing safe to join.
  func play(path: String, volume: Float) throws -> Double {
    stop()
    guard AVAudioSession.sharedInstance().category == .playAndRecord else {
      throw NoCallSession()
    }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    self.file = file
    self.volume = volume
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
    node.volume = volume
    try engine.start()
    observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in self?.restartAfterRouteChange() }
    schedule(from: 0)
    paused = false
    node.play()
    return Double(file.length) / file.processingFormat.sampleRate
  }

  func stop() {
    generation += 1
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    node.stop()
    if engine.isRunning { engine.stop() }
    engine.detach(node)
    file = nil
    startFrame = 0
    paused = false
  }

  func pause() {
    paused = true
    node.pause()
  }

  func resume() {
    paused = false
    if file != nil { node.play() }
  }

  func setVolume(_ volume: Float) {
    self.volume = volume
    node.volume = volume
  }

  func seek(seconds: Double) {
    guard let file else { return }
    let frame = AVAudioFramePosition(max(0, seconds) * file.processingFormat.sampleRate)
    node.stop()
    schedule(from: min(frame, max(file.length - 1, 0)))
    if !paused { node.play() }
  }

  var positionSeconds: Double {
    guard let file, let renderTime = node.lastRenderTime,
      let played = node.playerTime(forNodeTime: renderTime), file.length > 0
    else { return 0 }
    let first = file.length - startFrame
    let frames = played.sampleTime
    let into = frames < first ? startFrame + frames : (frames - first) % file.length
    return Double(into) / file.processingFormat.sampleRate
  }

  /// Plays from `frame` to the end, then queues whole-file loops behind it.
  private func schedule(from frame: AVAudioFramePosition) {
    guard let file else { return }
    generation += 1
    startFrame = frame
    let mine = generation
    let rest = AVAudioFrameCount(file.length - frame)
    node.scheduleSegment(file, startingFrame: frame, frameCount: rest, at: nil) { [weak self] in
      DispatchQueue.main.async { self?.queueLoop(generation: mine) }
    }
  }

  private func queueLoop(generation mine: Int) {
    guard mine == generation, let file else { return }
    node.scheduleFile(file, at: nil) { [weak self] in
      DispatchQueue.main.async { self?.queueLoop(generation: mine) }
    }
  }

  /// A route change (Bluetooth connecting, say) stops the engine; carry on from the top of the file.
  private func restartAfterRouteChange() {
    guard file != nil, !engine.isRunning else { return }
    try? engine.start()
    if !paused {
      node.stop()
      schedule(from: 0)
      node.play()
    }
  }
}
