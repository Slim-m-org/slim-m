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
    let id = UUID()
    let before = handle(
      ["call_id": id.uuidString, "caller": "Alice"],
      on: provider
    )
    XCTAssertTrue(before, "CallKit must be told before PushKit is released")
    XCTAssertEqual(provider.reported.count, 1)
    XCTAssertEqual(provider.reported.first?.uuid, id)
    XCTAssertEqual(provider.reported.first?.update.localizedCallerName, "Alice")
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

  func testAnUnparseableCallIdGetsAFreshOneRatherThanBeingDropped() {
    let provider = RecordingProvider()
    let before = handle(["call_id": "not-a-uuid"], on: provider)
    XCTAssertTrue(before)
    XCTAssertEqual(provider.reported.count, 1)
  }

  func testTheSameCallIdReportsTheSameCallRatherThanASecondOne() {
    // A duplicate push for one call must update it, not stack another on
    // screen, which is what a freshly generated id every time would do.
    let id = UUID()
    let payload: [AnyHashable: Any] = ["call_id": id.uuidString]
    XCTAssertEqual(VoipCallHandler.callId(from: payload), id)
    XCTAssertEqual(VoipCallHandler.callId(from: payload), id)
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
    let id = UUID()
    handler.handle(payload: ["call_id": id.uuidString]) {}
    XCTAssertEqual(seen, [.ringing(id)])
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
}
