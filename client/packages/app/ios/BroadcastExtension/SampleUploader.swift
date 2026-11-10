// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// Adapted from the LiveKit Flutter example's broadcast extension, which took
// it in turn from Jitsi Meet. The framing below is not ours to choose: the
// reader is flutter_webrtc's `FlutterSocketConnectionFrameReader`, which
// parses a serialized CFHTTPMessage with these exact header fields.
import Foundation
import OSLog
import ReplayKit

private enum Constants {
  /// One stream write. Larger writes block the ReplayKit callback thread,
  /// which drops frames rather than queueing them.
  static let bufferMaxLength = 10240
}

/// Turns each captured frame into a JPEG-bodied HTTP message and pushes it
/// down the socket a chunk at a time.
class SampleUploader {
  private static var imageContext = CIContext(options: nil)

  @Atomic private var isReady = false
  private var connection: SocketConnection

  private var dataToSend: Data?
  private var byteIndex = 0

  private let serialQueue: DispatchQueue

  init(connection: SocketConnection) {
    self.connection = connection
    self.serialQueue = DispatchQueue(label: "top.npcserver.slimm.broadcast.sampleUploader")
    setupConnection()
  }

  /// Drops the frame rather than queueing it when the previous one is still
  /// going out. A screen share that buffers is worse than one that skips.
  @discardableResult func send(sample buffer: CMSampleBuffer) -> Bool {
    guard isReady else { return false }
    // A frame that cannot be encoded leaves the latch alone, since nothing would re-arm it.
    guard let frame = prepare(sample: buffer) else { return false }
    isReady = false

    dataToSend = frame
    byteIndex = 0

    serialQueue.async { [weak self] in
      self?.sendDataChunk()
    }
    return true
  }
}

private extension SampleUploader {
  func setupConnection() {
    connection.didOpen = { [weak self] in
      self?.isReady = true
    }
    connection.streamHasSpaceAvailable = { [weak self] in
      self?.serialQueue.async {
        if let success = self?.sendDataChunk() {
          self?.isReady = !success
        }
      }
    }
  }

  @discardableResult func sendDataChunk() -> Bool {
    guard let dataToSend = dataToSend else { return false }

    var bytesLeft = dataToSend.count - byteIndex
    var length = bytesLeft > Constants.bufferMaxLength ? Constants.bufferMaxLength : bytesLeft

    length = dataToSend[byteIndex..<(byteIndex + length)].withUnsafeBytes {
      guard let ptr = $0.bindMemory(to: UInt8.self).baseAddress else { return 0 }
      return connection.writeToStream(buffer: ptr, maxLength: length)
    }

    if length > 0 {
      byteIndex += length
      bytesLeft -= length
      if bytesLeft == 0 {
        self.dataToSend = nil
        byteIndex = 0
      }
    } else {
      os_log(.debug, log: broadcastLogger, "writeBufferToStream failure")
    }

    return true
  }

  func prepare(sample buffer: CMSampleBuffer) -> Data? {
    guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else {
      os_log(.debug, log: broadcastLogger, "image buffer not available")
      return nil
    }

    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)

    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    let orientation =
      CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)?
      .uintValue ?? 0
    let bufferData = jpegData(from: imageBuffer)

    CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)

    guard let messageData = bufferData else {
      os_log(.debug, log: broadcastLogger, "corrupted image buffer")
      return nil
    }

    let httpResponse = CFHTTPMessageCreateResponse(nil, 200, nil, kCFHTTPVersion1_1)
      .takeRetainedValue()
    CFHTTPMessageSetHeaderFieldValue(
      httpResponse, "Content-Length" as CFString, String(messageData.count) as CFString)
    CFHTTPMessageSetHeaderFieldValue(
      httpResponse, "Buffer-Width" as CFString, String(width) as CFString)
    CFHTTPMessageSetHeaderFieldValue(
      httpResponse, "Buffer-Height" as CFString, String(height) as CFString)
    CFHTTPMessageSetHeaderFieldValue(
      httpResponse, "Buffer-Orientation" as CFString, String(orientation) as CFString)
    CFHTTPMessageSetBody(httpResponse, messageData as CFData)

    return CFHTTPMessageCopySerializedMessage(httpResponse)?.takeRetainedValue() as Data?
  }

  func jpegData(from buffer: CVPixelBuffer) -> Data? {
    let image = CIImage(cvPixelBuffer: buffer)
    guard let colorSpace = image.colorSpace else { return nil }

    let options: [CIImageRepresentationOption: Float] = [
      kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0
    ]
    return SampleUploader.imageContext.jpegRepresentation(
      of: image, colorSpace: colorSpace, options: options)
  }
}
