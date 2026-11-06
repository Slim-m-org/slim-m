// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call overlay goes on the screen picked for it, and falls back to the
/// app window's screen when that one is unplugged.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/call_overlay_panel.dart';
import 'package:slimm_platform/platform.dart';

OverlayMonitor _screen(int x) =>
    OverlayMonitor(x: x, y: 0, width: 1920, height: 1080, primary: x == 0);

void main() {
  final support = OverlaySupport(
    supported: true,
    monitors: [_screen(0), _screen(1920)],
  );

  test('a picked screen wins over the app window', () {
    expect(callOverlayMonitor(support, 0, chosen: '1920,0,1920,1080'), 1);
  });

  test('automatic follows the app window', () {
    expect(callOverlayMonitor(support, 1), 1);
    expect(callOverlayMonitor(support, 0), 0);
  });

  test('an unplugged pick falls back to the app window', () {
    expect(callOverlayMonitor(support, 0, chosen: '3840,0,1920,1080'), 0);
  });
}
