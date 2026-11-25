// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import AVFoundation
import CallKit
import Flutter
import Foundation

/// What [OutgoingCallLifecycle] tells CallKit about a call this app decided
/// to start, as distinct from [CallReporting] in `VoipCallHandler.swift`,
/// which is what an inbound VoIP push uses.
protocol OutgoingCallReporting {
  func reportOutgoingCall(with uuid: UUID, startedConnectingAt date: Date?)
  func reportOutgoingCall(with uuid: UUID, connectedAt date: Date?)
  func reportCall(with uuid: UUID, endedAt date: Date?, reason: CXCallEndedReason)
  func reportCall(with uuid: UUID, updated update: CXCallUpdate)
}

extension CXProvider: OutgoingCallReporting {}

/// Requests CallKit start or end a call. The seam a test drives instead of a
/// real `CXCallController`, which talks to the CallKit daemon and only runs
/// on a device or simulator, never in a plain XCTest process.
protocol CallRequesting {
  func requestStart(_ action: CXStartCallAction, completion: @escaping (Error?) -> Void)
  func requestEnd(_ action: CXEndCallAction, completion: @escaping (Error?) -> Void)
  func requestMute(_ action: CXSetMutedCallAction, completion: @escaping (Error?) -> Void)
}

extension CXCallController: CallRequesting {
  func requestStart(_ action: CXStartCallAction, completion: @escaping (Error?) -> Void) {
    request(CXTransaction(action: action), completion: completion)
  }

  func requestEnd(_ action: CXEndCallAction, completion: @escaping (Error?) -> Void) {
    request(CXTransaction(action: action), completion: completion)
  }

  func requestMute(_ action: CXSetMutedCallAction, completion: @escaping (Error?) -> Void) {
    request(CXTransaction(action: action), completion: completion)
  }
}

/// A CallKit action this class has to fulfil, as a seam rather than the
/// concrete `CXStartCallAction`/`CXEndCallAction`.
///
/// The seam exists because `fulfill()` does nothing to an action a test
/// constructed itself: an action only becomes complete when CallKit
/// delivered it inside a real `CXTransaction`, so `isComplete` stays false
/// off-device no matter what the code does. Asserting on it therefore tests
/// nothing, while failing to fulfil at all is a real bug - CallKit times the
/// action out and the call never starts. Recording the call through this
/// protocol is what makes the difference observable.
protocol CallActionFulfilling: AnyObject {
  var callUUID: UUID { get }
  func fulfill()
}

extension CXCallAction: CallActionFulfilling {}

/// A system mute request, as a seam for the same reason as [CallActionFulfilling].
protocol MuteActionFulfilling: CallActionFulfilling {
  var isMuted: Bool { get }
}

extension CXSetMutedCallAction: MuteActionFulfilling {}

/// Reports a call this app's own UI joined - never an inbound VoIP push - to
/// CallKit, so it gets the same background execution grant an incoming call
/// already gets; a join that follows an answered ring adopts that ring's call. See `VoipCallHandler.swift`'s doc comment and
/// https://github.com/NC1107/slim-m/issues/212.
///
/// CallKit has no "report a new outgoing call" entry point the way
/// `reportNewIncomingCall` exists for an inbound one: an outgoing call has to
/// be requested with a `CXStartCallAction` first, so [callStarted] asks and
/// [handleStartAction] (run from the provider delegate once CallKit grants
/// it) is where `reportOutgoingCall(startedConnectingAt:)` actually happens -
/// nothing may report anything before that point, since CallKit has no call
/// object yet to attach it to.
final class OutgoingCallLifecycle {
  private let controller: CallRequesting
  private let provider: OutgoingCallReporting
  private let onMain: MainHop

  init(controller: CallRequesting, provider: OutgoingCallReporting, onMain: @escaping MainHop = hopToMain) {
    self.controller = controller
    self.provider = provider
    self.onMain = onMain
  }

  private(set) var activeCallId: UUID?

  /// The id Dart named for [activeCallId]: the same call, unless it adopted an answered ring.
  private var namedByDart: UUID?
  private var adopted: Set<UUID> = []
  private var muted = false

  /// Calls this side asked CallKit to end, so their end action is not
  /// mistaken for the system UI hanging up and echoed back to Dart.
  private var endingLocally: Set<UUID> = []

  /// Runs when the system call UI ends this call (Dynamic Island, the lock
  /// screen), rather than this app's own hangup. Wired to tell the Dart side
  /// to actually leave the room: fulfilling the action alone would only end
  /// CallKit's own idea of the call and leave the room connected underneath.
  var onHangUp: (() -> Void)?

  /// The system call UI, AirPods or CarPlay muted or unmuted the call; Dart applies it to the microphone.
  var onMuteRequest: ((Bool) -> Void)?

  /// Each CallKit step and its result, for the call report only; see
  /// `call_system_event.dart` for the shape and the words.
  var onEvent: (([String: Any]) -> Void)?

  /// Holds WebRTC's audio back until CallKit activates the session.
  var audio: CallAudioHandOff?

  /// The ring the user answered that is still up, if any: one call per room, so an in-app join adopts it.
  var answeredCallId: (() -> UUID?)?

  /// True for a call this side reported, or adopted from an answered ring.
  func owns(_ id: UUID) -> Bool { activeCallId == id || endingLocally.contains(id) }

  func isAdopted(_ id: UUID) -> Bool { adopted.contains(id) }

  /// Asks CallKit to start reporting [id] as an outgoing call. A repeat for
  /// the call already active is a no-op, since CallKit tracks it already. A
  /// different id means the app moved the call to another account, so the
  /// older call is ended first and its own late end is then ignored.
  ///
  /// A join that follows an answered ring takes over that ring's call instead of starting a second one.
  func callStarted(id: UUID, displayName: String) {
    if activeCallId != nil {
      guard namedByDart != id else {
        report("start", result: "skipped")
        return
      }
      callEnded()
    }
    namedByDart = id
    muted = false
    if let answered = answeredCallId?() {
      activeCallId = answered
      adopted.insert(answered)
      report("start", result: "adopted")
      return
    }
    activeCallId = id
    audio?.begin(id)
    let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: displayName))
    action.isVideo = false
    controller.requestStart(action) { [weak self, onMain] error in
      onMain {
        self?.report("start", error: error)
        // CallKit refused the request (Do Not Disturb, another call already
        // up); nothing was reported, so nothing should still look active.
        guard error != nil, let self, self.activeCallId == id else { return }
        self.activeCallId = nil
        self.namedByDart = nil
        self.audio?.end(id)
      }
    }
  }

  /// CallKit grants the request from [callStarted] here.
  func handleStartAction(_ action: CallActionFulfilling) {
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    provider.reportCall(with: action.callUUID, updated: Self.unsupportedFeatures())
    action.fulfill()
    report("startAction")
  }

  /// Hold, grouping and DTMF are all refused, so the system never offers them for this call.
  static func unsupportedFeatures() -> CXCallUpdate {
    let update = CXCallUpdate()
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    return update
  }

  /// The room actually connected; [callId] names the call, so a late report for a replaced call is dropped.
  func callConnected(callId: UUID? = nil) {
    guard let id = activeCallId, isCurrent(callId) else {
      report("connected", result: "noCall")
      return
    }
    // An answered ring is connected as far as CallKit is concerned from the moment it was answered.
    if !adopted.contains(id) { provider.reportOutgoingCall(with: id, connectedAt: Date()) }
    report("connected")
  }

  /// This side ended the call. Safe to call with nothing active.
  ///
  /// A hangup on this device is a user action, so it goes to CallKit as an
  /// end request; `reportCall(endedAt:)` is only for a call ended elsewhere,
  /// and reporting it as remote-ended showed the wrong thing in Recents.
  ///
  /// [callId] names the call that ended: an end for any call but the active
  /// one is stale (the app has moved on to another) and is ignored.
  func callEnded(callId: UUID? = nil) {
    guard let id = activeCallId else { return }
    guard isCurrent(callId) else {
      report("end", result: "stale")
      return
    }
    clearActive()
    endingLocally.insert(id)
    controller.requestEnd(CXEndCallAction(call: id)) { [weak self, onMain] error in
      onMain {
        self?.report("end", error: error)
        // CallKit refused; report it ended anyway so no dead call lingers in the system UI.
        guard error != nil, let self, self.endingLocally.remove(id) != nil else { return }
        self.provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
      }
    }
  }

  /// CallKit delivers an end action, for this side's own request or because
  /// the system call UI hung up; only the latter must tell Dart to leave.
  /// Returns whether the system did it.
  @discardableResult
  func handleEndAction(_ action: CallActionFulfilling) -> Bool {
    let fromSystem = endingLocally.remove(action.callUUID) == nil
    if fromSystem {
      clearActive()
      onHangUp?()
    }
    adopted.remove(action.callUUID)
    action.fulfill()
    report("endAction", result: fromSystem ? "system" : "ok")
    return fromSystem
  }

  /// The system muted or unmuted the call: Dart applies it, and a repeat of what is already in force is only fulfilled.
  func handleMuteAction(_ action: MuteActionFulfilling) {
    if action.isMuted != muted {
      muted = action.isMuted
      onMuteRequest?(action.isMuted)
    }
    action.fulfill()
    report("muteAction", result: action.isMuted ? "muted" : "unmuted")
  }

  /// The app muted or unmuted, so the system call UI is told to agree.
  func muteChanged(_ isMuted: Bool) {
    guard let id = activeCallId, isMuted != muted else { return }
    muted = isMuted
    controller.requestMute(CXSetMutedCallAction(call: id, muted: isMuted)) { [weak self, onMain] error in
      onMain { self?.report("mute", error: error) }
    }
  }

  /// The provider was reset: CallKit has forgotten every call, so the room must be left.
  func reset() {
    let hadCall = activeCallId != nil
    clearActive()
    endingLocally = []
    adopted = []
    report("reset")
    if hadCall { onHangUp?() }
  }

  private func clearActive() {
    activeCallId = nil
    namedByDart = nil
    muted = false
  }

  private func isCurrent(_ callId: UUID?) -> Bool {
    callId == nil || callId == namedByDart || callId == activeCallId
  }

  private func report(_ step: String, error: Error? = nil, result: String? = nil) {
    var event: [String: Any] = [
      "kind": "callKit", "step": step, "result": result ?? (error == nil ? "ok" : "failed"),
    ]
    if let error = error as NSError? {
      event["domain"] = error.domain
      event["code"] = error.code
    }
    onEvent?(event)
  }
}

/// Reads the shared `AVAudioSession` and forwards its interruptions, route
/// changes and media services resets, for the call report only: it never
/// changes the session. Ports go by type, never by the device's own name.
final class AudioSessionObserver {
  var onEvent: (([String: Any]) -> Void)?
  private var observers: [NSObjectProtocol] = []

  func start() {
    guard observers.isEmpty else { return }
    observe(AVAudioSession.interruptionNotification) { info in
      var event: [String: Any] = ["kind": "interruption"]
      if let type = info[AVAudioSessionInterruptionTypeKey] as? UInt { event["type"] = Int(type) }
      if let options = info[AVAudioSessionInterruptionOptionKey] as? UInt { event["options"] = Int(options) }
      if let reason = info[AVAudioSessionInterruptionReasonKey] as? UInt { event["reason"] = Int(reason) }
      return event
    }
    observe(AVAudioSession.routeChangeNotification) { info in
      var event = AudioSessionObserver.snapshot()
      event["kind"] = "routeChange"
      if let reason = info[AVAudioSessionRouteChangeReasonKey] as? UInt { event["reason"] = Int(reason) }
      return event
    }
    observe(AVAudioSession.mediaServicesWereLostNotification) { _ in ["kind": "mediaServicesLost"] }
    observe(AVAudioSession.mediaServicesWereResetNotification) { _ in ["kind": "mediaServicesReset"] }
  }

  /// CallKit activating or deactivating the session for its call, with the session as it then is.
  static func callKitHandOff(active: Bool) -> [String: Any] {
    var event = snapshot()
    event["kind"] = "callKitAudio"
    event["active"] = active
    return event
  }

  static func snapshot() -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    let route = session.currentRoute
    return [
      "category": session.category.rawValue,
      "mode": session.mode.rawValue,
      "inputs": route.inputs.map { $0.portType.rawValue },
      "outputs": route.outputs.map { $0.portType.rawValue },
      "otherAudioPlaying": session.isOtherAudioPlaying,
      "inputAvailable": session.isInputAvailable,
    ]
  }

  private func observe(_ name: Notification.Name, _ describe: @escaping ([AnyHashable: Any]) -> [String: Any]) {
    let observer = NotificationCenter.default.addObserver(
      forName: name, object: AVAudioSession.sharedInstance(), queue: .main
    ) { [weak self] note in
      self?.onEvent?(describe(note.userInfo ?? [:]))
    }
    observers.append(observer)
  }
}

/// Bridges the app's own call joins to the Dart-side `top.npcserver.slimm/call_lifecycle` channel (see
/// `packages/platform/lib/src/call_lifecycle_channel.dart`).
///
/// It owns no `CXProvider`: `VoipPushRegistrar` holds the app's only one and routes every action for a
/// call this app joined to this class's [lifecycle]. One provider and one call per room, so answering a
/// ring and joining its room is one call in the system UI.
final class VoiceCallChannel: NSObject {
  static let name = "top.npcserver.slimm/call_lifecycle"

  let lifecycle: OutgoingCallLifecycle
  private let audioSession = AudioSessionObserver()
  private var flutterChannel: FlutterMethodChannel?

  init(provider: CXProvider) {
    lifecycle = OutgoingCallLifecycle(controller: CXCallController(queue: .main), provider: provider)
    super.init()
    lifecycle.onHangUp = { [weak self] in
      self?.flutterChannel?.invokeMethod("endCall", arguments: nil)
    }
    lifecycle.onMuteRequest = { [weak self] muted in
      self?.flutterChannel?.invokeMethod("muteRequest", arguments: ["muted": muted])
    }
    let sendEvent: ([String: Any]) -> Void = { [weak self] event in
      self?.flutterChannel?.invokeMethod("callEvent", arguments: event)
    }
    lifecycle.onEvent = sendEvent
    audioSession.onEvent = sendEvent
  }

  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    flutterChannel = channel
    audioSession.start()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "callStarted":
      handleCallStarted(call, result: result)
    case "callConnected":
      lifecycle.callConnected(callId: Self.callId(from: call))
      result(nil)
    case "callEnded":
      lifecycle.callEnded(callId: Self.callId(from: call))
      result(nil)
    case "callMuted":
      let args = call.arguments as? [String: Any]
      lifecycle.muteChanged(args?["muted"] as? Bool ?? false)
      result(nil)
    case "audioSession":
      result(AudioSessionObserver.snapshot())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func callId(from call: FlutterMethodCall) -> UUID? {
    guard let args = call.arguments as? [String: Any], let id = args["callId"] as? String else { return nil }
    return UUID(uuidString: id)
  }

  private func handleCallStarted(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let idString = args["callId"] as? String,
      let id = UUID(uuidString: idString),
      let displayName = args["displayName"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "callId/displayName missing or invalid", details: nil))
      return
    }
    lifecycle.callStarted(id: id, displayName: displayName)
    result(nil)
  }
}
