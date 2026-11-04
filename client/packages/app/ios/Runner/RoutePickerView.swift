// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import AVKit
import Flutter
import UIKit

/// The system audio route button (AirPods, speaker, this phone) as a Flutter
/// platform view; the Dart half is `AudioRoutePicker` in the voice feature.
final class RoutePickerFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "top.npcserver.slimm/route_picker"

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    RoutePickerPlatformView(frame: frame)
  }
}

private final class RoutePickerPlatformView: NSObject, FlutterPlatformView {
  private let picker: AVRoutePickerView

  init(frame: CGRect) {
    picker = AVRoutePickerView(frame: frame)
    picker.prioritizesVideoDevices = false
    super.init()
  }

  func view() -> UIView { picker }
}
