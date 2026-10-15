// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [DesktopWindowShell]'s receiving end of `linux_second_instance_channel.cc`
/// - proves it reuses [DesktopWindowPort.show]/[DesktopWindowPort.restore]
/// rather than a second implementation of "make the window visible again",
/// and that an unrelated method on the same channel is ignored.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';

import 'support/fake_desktop_window_port.dart';

const _channel = MethodChannel('top.npcserver.slimm/second_instance');

Future<void> _send(MethodCall call) async {
  final completer = Completer<ByteData?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(call),
        completer.complete,
      );
  await completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(DesktopWindowShell.debugReset);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMessageHandler(_channel.name, null);
    DesktopWindowShell.debugReset();
  });

  test('a focus notification shows and restores the window, the same calls '
      "the tray menu's own Show item makes", () async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    DesktopWindowShell.registerSecondInstanceHandler();

    await _send(const MethodCall('focus'));

    expect(port.showCalls, 1);
    expect(port.restoreCalls, 1);
  });

  test('an unrelated method on the same channel is ignored', () async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    DesktopWindowShell.registerSecondInstanceHandler();

    await _send(const MethodCall('somethingElse'));

    expect(port.showCalls, 0);
    expect(port.restoreCalls, 0);
  });

  test('a port that throws leaves nothing uncaught', () async {
    final port = _ThrowingShowPort();
    DesktopWindowShell.debugPort = port;
    DesktopWindowShell.registerSecondInstanceHandler();

    await _send(const MethodCall('focus'));

    expect(port.showCalls, 1);
  });
}

class _ThrowingShowPort extends FakeDesktopWindowPort {
  @override
  Future<void> show() async {
    showCalls++;
    throw StateError('no native window here');
  }
}
