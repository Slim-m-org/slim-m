// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import AVFoundation
import CallKit
import Foundation
import PushKit

/// The bundled CallKit ringtone, generated deterministically by
/// `assets/audio/generate.py` from `sounds.py`'s `CALLKIT_RINGTONE` and
/// copied into the Runner target's own bundle by `project.pbxproj`'s Audio
/// group - never hand-dropped, so `audio-ci` catches any drift from source.
let callKitRingtoneFileName = "callkit_ringtone.wav"

/// The one rule this file exists to keep.
///
/// Since iOS 13, an app that receives a VoIP push and does not report an
/// incoming call to CallKit before returning from the push handler is
/// terminated, and doing it repeatedly costs the app its VoIP push privileges
/// entirely. That makes it a correctness invariant rather than a nicety: every
/// path out of `handle` has to report, including the ones where the payload is
/// wrong, where the seal will not open, or where CallKit itself errors.
///
/// The tempting shape is to parse the payload, and bail early if it is
/// rubbish. That is exactly the bug: a malformed push is still a push, and
/// bailing is what gets the app killed. So a payload that cannot be understood
/// is reported as a call from an unknown caller and then immediately ended,
/// which is visible for an instant and survivable, instead of silently fatal.
///
/// A call joined from this app's own UI (not an inbound VoIP push) is a
/// separate path: `handle` below only ever runs from
/// `pushRegistry(_:didReceiveIncomingPushWith:...)`, and it is
/// `VoiceCallReporter.swift`'s `OutgoingCallLifecycle`, not this file, that
/// reports one to `CXProvider` on the outgoing side of the API. See that
/// file's doc comment and https://github.com/NC1107/slim-m/issues/212; it
/// still needs a real device to confirm end to end.
protocol CallReporting {
  func reportNewIncomingCall(
    with uuid: UUID,
    update: CXCallUpdate,
    completion: @escaping (Error?) -> Void
  )
  func reportCall(with uuid: UUID, endedAt: Date?, reason: CXCallEndedReason)
}

extension CXProvider: CallReporting {}

/// Hops to the main queue; CallKit's completions promise no queue of their own.
typealias MainHop = (@escaping () -> Void) -> Void

let hopToMain: MainHop = { work in DispatchQueue.main.async(execute: work) }

/// What CallKit is doing with a call this file reported, told to Dart so the
/// websocket's copy of the same ring is not prompted for a second time.
enum CallKitCallEvent: Equatable {
  case ringing(UUID)
  case answered(UUID)
  case ended(UUID)

  var wire: [String: String] {
    switch self {
    case .ringing(let id): return ["event": "ringing", "id": id.uuidString]
    case .answered(let id): return ["event": "answered", "id": id.uuidString]
    case .ended(let id): return ["event": "ended", "id": id.uuidString]
    }
  }
}

/// Turns a VoIP push payload into a reported CallKit call.
///
/// Deliberately separate from the PushKit delegate wiring so the invariant can
/// be tested: the delegate below is a few lines of glue, and everything worth
/// asserting on happens here against an injected `CallReporting`.
final class VoipCallHandler {
  /// Arms a ring timer to fire after a delay.
  typealias Schedule = (TimeInterval, DispatchWorkItem) -> Void

  private let provider: CallReporting
  private let schedule: Schedule
  private let onMain: MainHop
  private var ringTimers: [UUID: DispatchWorkItem] = [:]
  private let ringTimersLock = NSLock()
  private var answered: [UUID] = []

  /// Set after construction so the tests' one-argument initializer still works.
  var onEvent: ((CallKitCallEvent) -> Void)?

  /// Matches the server's ring timeout, past which the ring is over.
  static let ringTimeout: TimeInterval = 30

  /// Tests pass their own `schedule`: the hosted app can hold the main queue for longer than a ring window.
  init(
    provider: CallReporting,
    onMain: @escaping MainHop = hopToMain,
    schedule: @escaping Schedule = { delay, timer in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }
  ) {
    self.provider = provider
    self.onMain = onMain
    self.schedule = schedule
  }

  /// A call the user picked up must outlive the unanswered-ring timeout below.
  func callAnswered(_ id: UUID) {
    cancelRingTimer(id)
    ringTimersLock.lock()
    answered.append(id)
    ringTimersLock.unlock()
    onEvent?(.answered(id))
  }

  /// The call the user answered that is still up: the one an in-app join adopts instead of starting another.
  var answeredCallId: UUID? {
    ringTimersLock.lock()
    defer { ringTimersLock.unlock() }
    return answered.last
  }

  /// The user ended or declined the call on the system screen; [notifyDart] is false when Dart asked for it.
  func callEnded(_ id: UUID, notifyDart: Bool = true) {
    forget(id)
    if notifyDart { onEvent?(.ended(id)) }
  }

  /// Dart reports the ring or the in-app call over, so the system call must not linger.
  func endCall(_ id: UUID) {
    forget(id)
    provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
  }

  /// The provider was reset: CallKit forgot every call, so Dart is told each one ended.
  func reset() {
    ringTimersLock.lock()
    let live = Set(ringTimers.keys).union(answered)
    ringTimers.values.forEach { $0.cancel() }
    ringTimers = [:]
    answered = []
    ringTimersLock.unlock()
    for id in live.sorted(by: { $0.uuidString < $1.uuidString }) { onEvent?(.ended(id)) }
  }

  private func forget(_ id: UUID) {
    cancelRingTimer(id)
    ringTimersLock.lock()
    answered.removeAll { $0 == id }
    ringTimersLock.unlock()
  }

  /// The push is content-free, so no later push can say the caller hung up.
  private func startRingTimer(_ id: UUID) {
    let timer = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      guard self.replaceRingTimer(id, with: nil) != nil else { return }
      self.provider.reportCall(with: id, endedAt: Date(), reason: .unanswered)
      self.onEvent?(.ended(id))
    }
    replaceRingTimer(id, with: timer)?.cancel()
    schedule(VoipCallHandler.ringTimeout, timer)
  }

  /// A call that already ended must not report a second end that could hit a newer ring.
  private func cancelRingTimer(_ id: UUID) {
    replaceRingTimer(id, with: nil)?.cancel()
  }

  /// CallKit's completion and its delegate callbacks are not promised to share a queue.
  private func replaceRingTimer(_ id: UUID, with timer: DispatchWorkItem?) -> DispatchWorkItem? {
    ringTimersLock.lock()
    defer { ringTimersLock.unlock() }
    let previous = ringTimers[id]
    ringTimers[id] = timer
    return previous
  }

  /// The caller name every call shows.
  ///
  /// The relay delivers only the sealed envelope, which this target holds no key for,
  /// so there is no caller to read until the app is foregrounded and can resolve the channel.
  /// A generic string is the honest thing to display rather than a guess.
  static let unknownCaller = "Incoming call"

  /// The one entry point PushKit's delegate uses, so the type check lives where the
  /// invariant is tested. A non-VoIP type is never delivered to this registry, but
  /// completing it keeps PushKit from waiting on a push nobody will report.
  func handlePush(
    of type: PKPushType,
    payload: [AnyHashable: Any],
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    handle(payload: payload, completion: completion)
  }

  /// Handles one VoIP push. `completion` is PushKit's, and is called only
  /// after CallKit has been told about the call. The payload is sealed, so it is
  /// never read: every push is its own call.
  func handle(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
    let callId = UUID()
    let update = CXCallUpdate()
    update.localizedCallerName = Self.unknownCaller
    update.hasVideo = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsHolding = false

    // Reported before anything else can throw, return, or dispatch elsewhere.
    provider.reportNewIncomingCall(with: callId, update: update) { [provider, onMain, weak self] error in
      onMain {
        if error == nil {
          self?.onEvent?(.ringing(callId))
          self?.startRingTimer(callId)
        }
        if error != nil {
          // CallKit refused it (a call already up, Do Not Disturb, and so on).
          // Ending it keeps the app's own idea of active calls in step with
          // CallKit's, which is what stops a ghost call being left on screen.
          provider.reportCall(with: callId, endedAt: Date(), reason: .failed)
        }
        completion()
      }
    }
  }
}

/// Lets WebRTC start its audio unit only once CallKit has activated the session.
protocol CallAudioGating {
  func setManualAudio(_ on: Bool)
  func setAudioEnabled(_ on: Bool)
  func sessionActivated(_ session: AVAudioSession)
  func sessionDeactivated(_ session: AVAudioSession)
}

/// WebRTC's `RTCAudioSession`, reached by name because the Runner target does not link the WebRTC module.
final class WebRTCAudioGate: CallAudioGating {
  private let session: NSObject?

  init() {
    let sharedInstance = Selector(("sharedInstance"))
    var found: NSObject?
    for name in ["LKRTCAudioSession", "RTCAudioSession"] {
      guard let cls = NSClassFromString(name) else { continue }
      let type: AnyObject = cls
      guard type.responds(to: sharedInstance),
        let value = type.perform(sharedInstance)?.takeUnretainedValue() as? NSObject
      else { continue }
      found = value
      break
    }
    session = found
  }

  func setManualAudio(_ on: Bool) { set(on, "setUseManualAudio:", key: "useManualAudio") }

  func setAudioEnabled(_ on: Bool) { set(on, "setIsAudioEnabled:", key: "isAudioEnabled") }

  /// setValue(_:forKey:) raises on an unknown key, so the setter is checked first.
  private func set(_ on: Bool, _ setter: String, key: String) {
    guard let target = session, target.responds(to: Selector((setter))) else { return }
    target.setValue(on, forKey: key)
  }

  func sessionActivated(_ session: AVAudioSession) { notify("audioSessionDidActivate:", session) }

  func sessionDeactivated(_ session: AVAudioSession) { notify("audioSessionDidDeactivate:", session) }

  private func notify(_ name: String, _ session: AVAudioSession) {
    let selector = Selector((name))
    guard let target = self.session, target.responds(to: selector) else { return }
    _ = target.perform(selector, with: session)
  }
}

/// Hands the audio session to WebRTC the way CallKit expects: audio is held off from the moment a
/// call is reported until `didActivate`, so a join cannot start the audio unit on a session CallKit
/// has not given the app yet. With no call reported WebRTC manages the session itself, as before.
final class CallAudioHandOff {
  /// Without a `didActivate` this soon after a call is reported, audio is enabled anyway rather than left silent.
  static let activationGrace: TimeInterval = 5

  private let gate: CallAudioGating
  private let schedule: VoipCallHandler.Schedule
  private var calls: Set<UUID> = []
  private var fallback: DispatchWorkItem?
  private var active = false

  init(
    gate: CallAudioGating = WebRTCAudioGate(),
    schedule: @escaping VoipCallHandler.Schedule = { delay, work in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
  ) {
    self.gate = gate
    self.schedule = schedule
  }

  /// A call was reported, or is about to be requested.
  func begin(_ id: UUID) {
    let first = calls.isEmpty
    calls.insert(id)
    guard first else { return }
    gate.setManualAudio(true)
    guard !active else {
      gate.setAudioEnabled(true)
      return
    }
    gate.setAudioEnabled(false)
    armFallback()
  }

  /// The call is over, or CallKit refused it; the last one hands the session back to WebRTC.
  func end(_ id: UUID) {
    guard calls.remove(id) != nil, calls.isEmpty else { return }
    fallback?.cancel()
    fallback = nil
    gate.setAudioEnabled(true)
    gate.setManualAudio(false)
  }

  func endAll() {
    for id in calls { end(id) }
  }

  func didActivate(_ session: AVAudioSession) {
    active = true
    fallback?.cancel()
    fallback = nil
    gate.sessionActivated(session)
    if !calls.isEmpty { gate.setAudioEnabled(true) }
  }

  func didDeactivate(_ session: AVAudioSession) {
    active = false
    if !calls.isEmpty { gate.setAudioEnabled(false) }
    gate.sessionDeactivated(session)
  }

  private func armFallback() {
    fallback?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.calls.isEmpty else { return }
      self.gate.setAudioEnabled(true)
    }
    fallback = work
    schedule(Self.activationGrace, work)
  }
}

/// Registers for VoIP pushes and hands them to [VoipCallHandler].
///
/// Owns the app's one `CXProvider` and is its only delegate: an incoming ring and a call joined from
/// the app's own UI are one call to CallKit, and the actions for either arrive here. Anything about a
/// call the app itself joined goes to [outgoing], by call UUID.
///
/// Kept apart from `AppDelegate` because the delegate already carries the APNs
/// path; these are two different push types with two different failure modes,
/// and mixing them makes it hard to see that the rule above is being kept.
final class VoipPushRegistrar: NSObject, PKPushRegistryDelegate, CXProviderDelegate {
  private let registry: PKPushRegistry
  let provider: CXProvider
  private let handler: VoipCallHandler
  let audio = CallAudioHandOff()

  /// The in-app side of the same provider; set once the Flutter engine exists.
  var outgoing: OutgoingCallLifecycle? {
    didSet {
      guard let outgoing else { return }
      let handler = self.handler
      outgoing.audio = audio
      outgoing.answeredCallId = { [weak handler] in handler?.answeredCallId }
    }
  }

  /// Called with the VoIP token so the Dart side can register it with the
  /// server, alongside the ordinary APNs token.
  var onToken: ((String) -> Void)?

  /// Called as CallKit's view of an incoming call changes, for the Dart side.
  var onCallEvent: ((CallKitCallEvent) -> Void)?

  override init() {
    registry = PKPushRegistry(queue: .main)

    // The localizedName initializer rather than the empty one: this name is
    // what the system call UI and the Recents list show, and neither should
    // say nothing.
    let configuration = CXProviderConfiguration(localizedName: "slim-m")
    configuration.supportsVideo = false
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    configuration.includesCallsInRecents = false
    configuration.ringtoneSound = callKitRingtoneFileName
    provider = CXProvider(configuration: configuration)

    handler = VoipCallHandler(provider: provider)
    super.init()

    handler.onEvent = { [weak self] event in self?.onCallEvent?(event) }
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    provider.setDelegate(self, queue: .main)
  }

  func endCall(_ id: UUID) {
    audio.end(id)
    handler.endCall(id)
  }

  // MARK: PKPushRegistryDelegate

  func pushRegistry(
    _: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    onToken?(hex)
  }

  func pushRegistry(
    _: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    handler.handlePush(of: type, payload: payload.dictionaryPayload, completion: completion)
  }

  // MARK: CXProviderDelegate

  func providerDidReset(_: CXProvider) {
    audio.endAll()
    handler.reset()
    outgoing?.reset()
  }

  func provider(_: CXProvider, didActivate session: AVAudioSession) {
    audio.didActivate(session)
    outgoing?.onEvent?(AudioSessionObserver.callKitHandOff(active: true))
  }

  func provider(_: CXProvider, didDeactivate session: AVAudioSession) {
    audio.didDeactivate(session)
    outgoing?.onEvent?(AudioSessionObserver.callKitHandOff(active: false))
  }

  func provider(_: CXProvider, perform action: CXAnswerCallAction) {
    audio.begin(action.callUUID)
    handler.callAnswered(action.callUUID)
    // Fulfilled so CallKit does not show a failed call; Dart is told and joins the room.
    action.fulfill()
  }

  func provider(_: CXProvider, perform action: CXStartCallAction) {
    guard let outgoing else {
      action.fail()
      return
    }
    outgoing.handleStartAction(action)
  }

  func provider(_: CXProvider, perform action: CXEndCallAction) {
    let id = action.callUUID
    audio.end(id)
    guard let outgoing, outgoing.owns(id) else {
      handler.callEnded(id)
      action.fulfill()
      return
    }
    let adopted = outgoing.isAdopted(id)
    let fromSystem = outgoing.handleEndAction(action)
    if adopted { handler.callEnded(id, notifyDart: fromSystem) }
  }

  func provider(_: CXProvider, perform action: CXSetMutedCallAction) {
    guard let outgoing else {
      action.fulfill()
      return
    }
    outgoing.handleMuteAction(action)
  }

  /// Holding is declared unsupported on every call, so a hold request is refused outright.
  func provider(_: CXProvider, perform action: CXSetHeldCallAction) {
    action.fail()
  }
}
