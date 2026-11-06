// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The window's own focus and minimise events keep the lifecycle honest when
/// the embedder leaves it stale, as it can after a locked screen or a launch
/// behind another window.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<DesktopWindowEventKind> events;
  late AppLifecycleNotifier life;

  setUp(() {
    events = StreamController<DesktopWindowEventKind>.broadcast(sync: true);
    life = AppLifecycleNotifier(mobile: false, windowEvents: events.stream);
  });

  tearDown(() async {
    life.dispose();
    await events.close();
  });

  test('focus lifts a stale hidden state', () {
    life.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(life.state, AppLifecycleState.hidden);

    events.add(DesktopWindowEventKind.focus);
    expect(life.state, AppLifecycleState.resumed);
  });

  test('losing focus reads as inactive, not hidden', () {
    events.add(DesktopWindowEventKind.focus);
    events.add(DesktopWindowEventKind.blur);
    expect(life.state, AppLifecycleState.inactive);
  });

  test('a blur after minimising keeps the window hidden', () {
    events.add(DesktopWindowEventKind.minimize);
    events.add(DesktopWindowEventKind.blur);
    expect(life.state, AppLifecycleState.hidden);

    events.add(DesktopWindowEventKind.focus);
    expect(life.state, AppLifecycleState.resumed);
  });
}
