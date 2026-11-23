// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Web's side of the pop-out: never offered, and the main window is the page.
library;

import 'popout_windowing.dart' show NativeMainWindow, PopOutWindowFactory;

PopOutWindowFactory? nativePopOutWindowFactory({
  bool? windowing,
  bool? linux,
  bool? windows,
}) => null;

Future<NativeMainWindow?> claimNativeMainWindow() async => null;
