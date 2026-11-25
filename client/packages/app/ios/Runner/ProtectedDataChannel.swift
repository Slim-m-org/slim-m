// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Flutter
import UIKit

/// Whether the device has been unlocked since boot, so the app does not read a
/// still-protected store as empty. The Dart half is
/// `lib/src/providers/fresh_install.dart`, which owns the channel name.
enum ProtectedDataChannel {
  static let name = "top.npcserver.slimm/protected_data"

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "isAvailable" else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.main.async {
      result(UIApplication.shared.isProtectedDataAvailable)
    }
  }
}
