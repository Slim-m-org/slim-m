import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    ClipboardImageChannel.register(with: flutterViewController.engine.binaryMessenger)
    AutostartChannel.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Answers the Dart side's clipboard image calls on the general pasteboard:
/// `writeImage` copies a PNG, `hasImage` and `readImage` let a paste read one
/// back as PNG. The channel name is owned by the Dart seam in
/// `clipboard_image_writer_io.dart` and `composer_clipboard_image_stub.dart`.
enum ClipboardImageChannel {
  static let name = "top.npcserver.slimm/clipboard_image"

  static func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: name, binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        switch call.method {
        case "hasImage":
          result(NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil))
          return
        case "readImage":
          result(readPng())
          return
        case "writeImage":
          break
        default:
          result(FlutterMethodNotImplemented)
          return
        }
        guard let data = (call.arguments as? FlutterStandardTypedData)?.data,
          let image = NSImage(data: data)
        else {
          result(FlutterError(code: "write_failed", message: "The image could not be copied.", details: nil))
          return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        result(pasteboard.writeObjects([image]) ? nil : FlutterError(
          code: "write_failed", message: "The image could not be copied.", details: nil))
      }
  }

  /// The pasteboard's image as PNG, or nil when it holds none.
  private static func readPng() -> FlutterStandardTypedData? {
    let pasteboard = NSPasteboard.general
    if let png = pasteboard.data(forType: .png) {
      return FlutterStandardTypedData(bytes: png)
    }
    guard let image = NSImage(pasteboard: pasteboard),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    return FlutterStandardTypedData(bytes: png)
  }
}

/// Answers `autostart_io.dart`'s login item calls with SMAppService's main-app
/// item, which needs macOS 13; older systems report it unsupported and the
/// setting is not offered. A login item gets no launch arguments, so a login
/// launch here opens normally rather than in the menu bar.
enum AutostartChannel {
  static let name = "top.npcserver.slimm/autostart"

  static func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: name, binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        guard #available(macOS 13.0, *) else {
          result(call.method == "isSupported" ? false : FlutterError(
            code: "unsupported", message: "Login items need macOS 13 or newer.", details: nil))
          return
        }
        switch call.method {
        case "isSupported":
          result(true)
        case "isEnabled":
          result(SMAppService.mainApp.status == .enabled)
        case "setEnabled":
          do {
            if (call.arguments as? Bool) == true {
              try SMAppService.mainApp.register()
            } else {
              try SMAppService.mainApp.unregister()
            }
            result(nil)
          } catch {
            result(FlutterError(code: "login_item_failed", message: error.localizedDescription, details: nil))
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
  }
}
