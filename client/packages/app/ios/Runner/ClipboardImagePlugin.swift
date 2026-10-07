// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Flutter
import UIKit

/// The app half of the composer's mobile paste bridge; the Dart half is
/// `composer_clipboard_image_stub.dart`, which owns the channel name.
///
/// Flutter's own paste path cannot reach this: `EditableText.pasteText()`
/// only ever calls `Clipboard.getData(Clipboard.kTextPlain)`, and the
/// engine's `FlutterTextInputPlugin.canPerformAction:` deliberately answers
/// `hasStrings` for the system `paste:` action - "Forbid pasting images,
/// memojis, or other non-string content," in its own comment. So a real
/// image paste on iOS needs a hand-written bridge, not an extension of the
/// text-editing path.
///
/// `hasImage`/`readImage` below back the composer's "+" sheet row: a poll
/// (metadata only, never prompts) and a tap (a real pasteboard read, which
/// **prompts on every call** - confirmed on a real device 2026-08-01, not
/// once per install as first assumed; see `ClipboardPasteBridge.m` for the
/// route that does not prompt at all.
enum ClipboardImagePlugin {
  static let name = "top.npcserver.slimm/clipboard_image"

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "hasImage":
      result(UIPasteboard.general.hasImages)
    case "readImage":
      result(UIPasteboard.general.image?.pngData())
    case "writeImage":
      guard let data = (call.arguments as? FlutterStandardTypedData)?.data,
        let image = UIImage(data: data)
      else {
        result(FlutterError(code: "write_failed", message: "The image could not be copied.", details: nil))
        return
      }
      UIPasteboard.general.image = image
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
