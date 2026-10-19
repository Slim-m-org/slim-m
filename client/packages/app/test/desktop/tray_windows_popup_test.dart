// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Windows reports a tray right-click but draws no menu until asked to.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/tray/desktop_tray_controller.dart';

import '../features/voice/voice_controller_harness.dart';
import 'support/fake_desktop_window_port.dart';

const _channel = MethodChannel('tray_manager');

Future<void> _platformEvent(String method) async {
  final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(_channel.name, data, (_) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<FakeDesktopWindowPort> leftClick({required bool windows}) async {
    final harness = VoiceHarness();
    harness.controllerWith(FakeSession(), voiceApi());
    addTearDown(harness.dispose);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => true);
    final port = FakeDesktopWindowPort();
    final controller = DesktopTrayController(
      port: port,
      container: harness.container,
      windows: windows,
    );
    await controller.start();
    await _platformEvent('onTrayIconMouseDown');
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    return port;
  }

  test(
    'a left-click on the Windows tray icon shows, restores and focuses',
    () async {
      final port = await leftClick(windows: true);
      expect((port.showCalls, port.restoreCalls, port.focusCalls), (1, 1, 1));
    },
  );

  test('a left-click elsewhere leaves the window alone', () async {
    final port = await leftClick(windows: false);
    expect((port.showCalls, port.restoreCalls, port.focusCalls), (0, 0, 0));
  });

  Future<List<MethodCall>> rightClick({required bool windows}) async {
    final harness = VoiceHarness();
    harness.controllerWith(FakeSession(), voiceApi());
    addTearDown(harness.dispose);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return true;
        });
    final controller = DesktopTrayController(
      port: FakeDesktopWindowPort(),
      container: harness.container,
      windows: windows,
    );
    await controller.start();
    await _platformEvent('onTrayIconRightMouseDown');
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    return calls;
  }

  test('a right-click on the Windows tray icon pops the menu up', () async {
    final calls = await rightClick(windows: true);
    expect(calls.where((c) => c.method == 'popUpContextMenu'), hasLength(1));
  });

  test('other platforms keep their native menu and are not popped', () async {
    final calls = await rightClick(windows: false);
    expect(calls.where((c) => c.method == 'popUpContextMenu'), isEmpty);
  });
}
