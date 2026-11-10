// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// Adapted from the LiveKit Flutter example's broadcast extension.
import OSLog
import ReplayKit

/// The ReplayKit entry point, named by `NSExtensionPrincipalClass` in this
/// target's `Info.plist` as `$(PRODUCT_MODULE_NAME).SampleHandler`.
///
/// Why this target has to exist at all: an iOS app cannot capture anything
/// outside its own window. Only a broadcast upload extension gets the frames,
/// and it is a separate process, so the frames reach the app over a unix
/// socket in a shared App Group container. Without this target the app's
/// screen share button calls `RPSystemBroadcastPickerView` with no extension
/// to offer, and nothing happens at all.
///
/// The app half of this socket lives in flutter_webrtc
/// (`FlutterBroadcastScreenCapturer`), and it finds the same file by reading
/// `RTCAppGroupIdentifier` out of the app's `Info.plist`.
class SampleHandler: RPBroadcastSampleHandler {
  /// The callback below is a C function pointer and cannot capture context,
  /// so it reaches the live handler through this instead.
  private static weak var current: SampleHandler?

  /// How long to wait for the app to create its end of the socket before giving up.
  private static let connectDeadline: TimeInterval = 10
  private static let unavailableMessage = "Screen sharing is not available. Open slim-m and try again."

  private var clientConnection: SocketConnection?
  private var uploader: SampleUploader?
  private var connectTimer: DispatchSourceTimer?

  private var socketFilePath: String? {
    let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: BroadcastConstants.appGroupIdentifier)
    return container?.appendingPathComponent(BroadcastConstants.socketFileName).path
  }

  override init() {
    super.init()
    SampleHandler.current = self

    if let path = socketFilePath, let connection = SocketConnection(filePath: path) {
      clientConnection = connection
      setupConnection()
      uploader = SampleUploader(connection: connection)
    }
    os_log(.debug, log: broadcastLogger, "broadcast socket at %{public}s", socketFilePath ?? "none")
  }

  override func broadcastStarted(withSetupInfo _: [String: NSObject]?) {
    guard clientConnection != nil else {
      finish(code: 10002, message: SampleHandler.unavailableMessage)
      return
    }
    DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
    observeStopRequest()
    openConnection()
  }

  override func broadcastFinished() {
    connectTimer?.cancel()
    connectTimer = nil
    DarwinNotificationCenter.shared.removeObserver(
      Unmanaged.passUnretained(self).toOpaque(), for: .broadcastRequestStop)
    DarwinNotificationCenter.shared.postNotification(.broadcastStopped)
    clientConnection?.close()
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType
  ) {
    switch sampleBufferType {
    case RPSampleBufferType.video:
      uploader?.send(sample: sampleBuffer)
    default:
      break
    }
  }
}

private extension SampleHandler {
  /// Lets the app's own "Stop sharing" button end the broadcast, instead of
  /// leaving the system status bar the only way out. livekit_client posts
  /// this notification from `BroadcastManager.requestStop()`.
  func observeStopRequest() {
    DarwinNotificationCenter.shared.addObserver(
      Unmanaged.passUnretained(self).toOpaque(),
      for: .broadcastRequestStop
    ) { _, _, _, _, _ in
      SampleHandler.current?.finishRequestedByApp()
    }
  }

  /// ReplayKit offers no way to end a broadcast without an error, so this
  /// reports a named one. It reads as "Screen sharing stopped" rather than a
  /// crash, which is the least misleading option available.
  func finishRequestedByApp() {
    finish(code: 10001, message: "Screen sharing stopped")
  }

  func finish(code: Int, message: String) {
    let error = NSError(
      domain: RPRecordingErrorDomain,
      code: code,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
    finishBroadcastWithError(error)
  }

  func setupConnection() {
    clientConnection?.didClose = { [weak self] error in
      os_log(.debug, log: broadcastLogger, "client connection did close")
      if let error = error {
        self?.finishBroadcastWithError(error)
      } else {
        self?.finishRequestedByApp()
      }
    }
  }

  /// The app creates the socket only once it is ready to receive, which can
  /// be after the broadcast starts, so this polls rather than failing once.
  func openConnection() {
    let queue = DispatchQueue(label: "top.npcserver.slimm.broadcast.connectTimer")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let giveUpAt = DispatchTime.now() + SampleHandler.connectDeadline
    timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(500))
    timer.setEventHandler { [weak self] in
      if self?.clientConnection?.open() == true {
        timer.cancel()
      } else if DispatchTime.now() >= giveUpAt {
        timer.cancel()
        self?.finish(code: 10002, message: SampleHandler.unavailableMessage)
      }
    }
    connectTimer = timer
    timer.resume()
  }
}
