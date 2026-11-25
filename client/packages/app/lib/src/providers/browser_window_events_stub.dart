// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The non-web half of `browser_window_events.dart`: no browser window here.
library;

import '../desktop/desktop_window_port.dart';

Stream<DesktopWindowEventKind> browserWindowEvents() => const Stream.empty();
