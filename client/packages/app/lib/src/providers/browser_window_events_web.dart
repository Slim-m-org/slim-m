// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser half of `browser_window_events.dart`.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../desktop/desktop_window_port.dart';

Stream<DesktopWindowEventKind> browserWindowEvents() {
  late final StreamController<DesktopWindowEventKind> events;
  final blur = (() => events.add(DesktopWindowEventKind.blur)).toJS;
  final focus = (() => events.add(DesktopWindowEventKind.focus)).toJS;
  events = StreamController<DesktopWindowEventKind>.broadcast(
    onListen: () {
      web.window.addEventListener('blur', blur);
      web.window.addEventListener('focus', focus);
    },
    onCancel: () {
      web.window.removeEventListener('blur', blur);
      web.window.removeEventListener('focus', focus);
    },
  );
  return events.stream;
}
