// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which monitor the Linux screen-share portal's chooser picked.
library;

import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The monitor a portal share covers, in the compositor's logical coordinates.
typedef PortalMonitor = ({int x, int y, int width, int height});

const _webrtcChannel = MethodChannel('FlutterWebRTC.Method');

/// The monitor picked in the portal's chooser for the share now running, or
/// null when the portal did not say (GNOME, a window share, any other platform).
///
/// libwebrtc keeps only the video stream from the portal's reply; the fork
/// watches the session bus for the monitor's position that rides along with it.
Future<PortalMonitor?> portalSharedMonitor() async {
  try {
    final reply = await _webrtcChannel.invokeMethod<Object?>(
      'portalStreamGeometry',
    );
    return portalMonitorFromReply(reply);
  } on MissingPluginException catch (error, stack) {
    AppLog.swallowed(
        LogTag.voice, 'Could not ask which monitor is shared', error, stack);
    return null;
  } on PlatformException catch (error, stack) {
    AppLog.swallowed(
        LogTag.voice, 'Could not ask which monitor is shared', error, stack);
    return null;
  }
}

/// The plugin's reply, or null when it is anything but a whole monitor.
PortalMonitor? portalMonitorFromReply(Object? reply) {
  if (reply is! Map) return null;
  final x = reply['x'], y = reply['y'];
  final width = reply['width'], height = reply['height'];
  if (x is! int || y is! int || width is! int || height is! int) return null;
  return (x: x, y: y, width: width, height: height);
}
