// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import CallKit
import PushKit
import XCTest

@testable import Runner

/// A stand-in for CXProvider that records what it was told and lets a test
/// decide whether CallKit accepts the call.
private final class RecordingProvider: CallReporting {
  var reported: [(uuid: UUID, update: CXCallUpdate)] = []
  var ended: [(uuid: UUID, reason: CXCallEndedReason)] = []
  var reportError: Error?

  func reportNewIncomingCall(
    with uuid: UUID,
    update: CXCallUpdate,
    completion: @escaping (Error?) -> Void
  ) {
    reported.append((uuid, update))
    completion(reportError)
  }

  func reportCall(with uuid: UUID, endedAt _: Date?, reason: CXCallEndedReason) {
    ended.append((uuid, reason))
  }
}

/// The CallKit synchronous-report invariant.
///
/// iOS terminates an app that takes a VoIP push and does not report a call
/// before the push handler returns, and repeat offences cost it VoIP push
/// entirely. So the assertion in every one of these is the same: a call was
/// reported, and it was reported before completion ran. The interesting part
/// is the inputs, which are all the ways a real push can be disappointing.
final class VoipCallHandlerTests: XCTestCase {
  private func handle(_ payload: [AnyHashable: Any], on provider: RecordingProvider) -> Bool {
    var completed = false
    var reportedBeforeCompletion = false
    let handler = VoipCallHandler(provider: provider)
    handler.handle(payload: payload) {
      reportedBeforeCompletion = !provider.reported.isEmpty
      completed = true
    }
    XCTAssertTrue(completed, "the push handler must complete, not hang")
    return reportedBeforeCompletion
  }

  func testAWellFormedPushReportsBeforeCompleting() {
    let provider = RecordingProvider()
    let before = handle(["kind": "call", "payload": "sealed"], on: provider)
    XCTAssertTrue(before, "CallKit must be told before PushKit is released")
    XCTAssertEqual(provider.reported.count, 1)
    XCTAssertEqual(
      provider.reported.first?.update.localizedCallerName,
      VoipCallHandler.unknownCaller
    )
  }

  func testAnEmptyPayloadStillReportsACall() {
    // The one that kills apps. Parsing nothing useful out of a push is not a
    // reason to skip reporting; it is a reason to report an unknown caller.
    let provider = RecordingProvider()
    let before = handle([:], on: provider)
    XCTAssertTrue(before, "a payload we cannot read is still a push we must report")
    XCTAssertEqual(provider.reported.count, 1)
    XCTAssertEqual(
      provider.reported.first?.update.localizedCallerName,
      VoipCallHandler.unknownCaller
    )
  }

  func testGarbageFieldsStillReportACall() {
    let provider = RecordingProvider()
    let before = handle(
      ["call_id": 42, "caller": ["not", "a", "string"]],
      on: provider
    )
    XCTAssertTrue(before)
    XCTAssertEqual(provider.reported.count, 1)
    XCTAssertEqual(
      provider.reported.first?.update.localizedCallerName,
      VoipCallHandler.unknownCaller
    )
  }

  func testEveryPushIsItsOwnCall() {
    // The envelope is sealed, so no id in a payload can say two pushes are one call.
    let provider = RecordingProvider()
    _ = handle(["call_id": UUID().uuidString], on: provider)
    _ = handle(["call_id": UUID().uuidString], on: provider)
    XCTAssertEqual(provider.reported.count, 2)
    XCTAssertNotEqual(provider.reported[0].uuid, provider.reported[1].uuid)
  }

  func testACallKitRefusalEndsTheCallAndStillCompletes() {
    // CallKit can refuse (another call is up, Do Not Disturb). The push must
    // still complete, and the call must not be left on screen.
    let provider = RecordingProvider()
    provider.reportError = NSError(domain: "CXErrorDomain", code: 3)
    let before = handle(["caller": "Alice"], on: provider)
    XCTAssertTrue(before)
    XCTAssertEqual(provider.ended.count, 1, "a refused call must be ended, not left hanging")
    XCTAssertEqual(provider.ended.first?.reason, .failed)
  }

  func testAVoipTypedPushGoesThroughTheReportingPath() {
    let provider = RecordingProvider()
    var completed = false
    var reportedBeforeCompletion = false
    VoipCallHandler(provider: provider).handlePush(of: .voIP, payload: [:]) {
      reportedBeforeCompletion = !provider.reported.isEmpty
      completed = true
    }
    XCTAssertTrue(completed)
    XCTAssertTrue(reportedBeforeCompletion, "the PushKit entry point must report before completing")
  }

  func testAnUnexpectedPushTypeStillCompletes() {
    let provider = RecordingProvider()
    var completed = false
    VoipCallHandler(provider: provider).handlePush(
      of: PKPushType(rawValue: "com.example.other"), payload: [:]
    ) { completed = true }
    XCTAssertTrue(completed, "PushKit must never be left waiting on a push")
  }

  func testAReportedCallTellsDartItIsRingingAfterTheReport() {
    let provider = RecordingProvider()
    let handler = VoipCallHandler(provider: provider)
    var seen: [CallKitCallEvent] = []
    var reportedWhenTold = false
    handler.onEvent = { event in
      reportedWhenTold = !provider.reported.isEmpty
      seen.append(event)
    }
    handler.handle(payload: [:]) {}
    guard let id = provider.reported.first?.uuid else { return XCTFail("nothing was reported") }
    XCTAssertEqual(seen, [CallKitCallEvent.ringing(id)])
    XCTAssertTrue(reportedWhenTold, "Dart is told only once CallKit has the call")
  }

  func testARefusedCallIsNotAnnouncedAsRinging() {
    let provider = RecordingProvider()
    provider.reportError = NSError(domain: "CXErrorDomain", code: 3)
    let handler = VoipCallHandler(provider: provider)
    var seen: [CallKitCallEvent] = []
    handler.onEvent = { seen.append($0) }
    handler.handle(payload: [:]) {}
    XCTAssertEqual(seen, [], "a call CallKit refused never rang")
  }

  func testAnswerAndEndAreForwardedToDart() {
    let handler = VoipCallHandler(provider: RecordingProvider())
    var seen: [CallKitCallEvent] = []
    handler.onEvent = { seen.append($0) }
    let id = UUID()
    handler.callAnswered(id)
    handler.callEnded(id)
    XCTAssertEqual(seen, [.answered(id), .ended(id)])
  }

  func testTheWireFormatMatchesWhatDartParses() {
    let id = UUID()
    XCTAssertEqual(CallKitCallEvent.answered(id).wire, ["event": "answered", "id": id.uuidString])
    XCTAssertEqual(CallKitCallEvent.ringing(id).wire["event"], "ringing")
    XCTAssertEqual(CallKitCallEvent.ended(id).wire["event"], "ended")
  }

  func testEndingAnAnsweredCallReportsItOverWithoutAnEvent() {
    let provider = RecordingProvider()
    let handler = VoipCallHandler(provider: provider)
    var seen: [CallKitCallEvent] = []
    handler.onEvent = { seen.append($0) }
    let id = UUID()
    handler.callAnswered(id)
    seen.removeAll()

    handler.endCall(id)

    XCTAssertEqual(provider.ended.first?.uuid, id)
    XCTAssertEqual(provider.ended.first?.reason, .remoteEnded)
    XCTAssertTrue(seen.isEmpty, "Dart asked for this end, so it needs no echo")
  }

  private func ring(
    _ handler: VoipCallHandler,
    provider: RecordingProvider
  ) -> UUID {
    handler.handle(payload: [:]) {}
    return provider.reported[provider.reported.count - 1].uuid
  }

  /// The timeout only bounds a hang: the hosted app can hold the main queue past 2 s while it boots.
  private func letTheRingWindowPass() {
    let passed = expectation(description: "the ring window passed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { passed.fulfill() }
    wait(for: [passed], timeout: 10)
  }

  func testAnUnansweredRingEndsAfterTheTimeout() {
    let provider = RecordingProvider()
    let handler = VoipCallHandler(provider: provider, ringTimeout: 0.05)
    var seen: [CallKitCallEvent] = []
    handler.onEvent = { seen.append($0) }

    let id = ring(handler, provider: provider)
    letTheRingWindowPass()

    XCTAssertEqual(provider.ended.map { $0.reason }, [.unanswered])
    XCTAssertEqual(seen, [.ringing(id), .ended(id)])
  }

  func testADeclinedRingNeverTimesOutLater() {
    // A stale end could otherwise decline a newer ring Dart is holding.
    let provider = RecordingProvider()
    let handler = VoipCallHandler(provider: provider, ringTimeout: 0.05)
    var seen: [CallKitCallEvent] = []
    handler.onEvent = { seen.append($0) }

    let id = ring(handler, provider: provider)
    handler.callEnded(id)
    letTheRingWindowPass()

    XCTAssertEqual(seen, [.ringing(id), .ended(id)])
    XCTAssertTrue(provider.ended.isEmpty)
  }

  func testACallDartEndedNeverTimesOutLater() {
    let provider = RecordingProvider()
    let handler = VoipCallHandler(provider: provider, ringTimeout: 0.05)
    var seen: [CallKitCallEvent] = []
    handler.onEvent = { seen.append($0) }

    let id = ring(handler, provider: provider)
    handler.endCall(id)
    letTheRingWindowPass()

    XCTAssertEqual(seen, [.ringing(id)])
    XCTAssertEqual(provider.ended.map { $0.reason }, [.remoteEnded])
  }

  func testAnAnsweredRingOutlivesTheTimeout() {
    let provider = RecordingProvider()
    let handler = VoipCallHandler(provider: provider, ringTimeout: 0.05)
    var seen: [CallKitCallEvent] = []
    handler.onEvent = { seen.append($0) }

    let id = ring(handler, provider: provider)
    handler.callAnswered(id)
    letTheRingWindowPass()

    XCTAssertEqual(seen, [.ringing(id), .answered(id)])
    XCTAssertTrue(provider.ended.isEmpty)
  }
}
