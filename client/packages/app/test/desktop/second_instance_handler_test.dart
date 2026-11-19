// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [DesktopWindowShell]'s receiving end of `linux_second_instance_channel.cc`
/// and the Windows runner's `single_instance.cpp` - proves it reuses
/// [DesktopWindowPort.show]/[DesktopWindowPort.restore] rather than a second
/// implementation of "make the window visible again", that a forwarded link
/// is passed on, and that an unrelated method on the same channel is ignored.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';

import 'support/fake_desktop_window_port.dart';
import 'support/desktop_shell_fixture.dart';

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

late DesktopWindowShell shell;

void main() {
  setUp(() => shell = shellFor(null));
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMessageHandler(_channel.name, null);
  });

  test('a focus notification shows and restores the window, the same calls '
      "the tray menu's own Show item makes", () async {
    final port = FakeDesktopWindowPort();
    shell = shellFor(port);
    shell.registerSecondInstanceHandler();

    await _send(const MethodCall('focus'));

    expect(port.showCalls, 1);
    expect(port.restoreCalls, 1);
  });

  test('on Windows a focus notification leaves a maximized window maximized, '
      'restoring only a minimized one', () async {
    final port = FakeDesktopWindowPort();
    shell = shellFor(port, chrome: DesktopPlatform.windows);
    shell.registerSecondInstanceHandler();

    await _send(const MethodCall('focus'));
    expect(port.showCalls, 1);
    expect(port.restoreCalls, 0);

    port.minimized = true;
    await _send(const MethodCall('focus'));
    expect(port.restoreCalls, 1);
  });

  test('a focus notification tells listeners another launch arrived', () async {
    shell = shellFor(FakeDesktopWindowPort());
    shell.registerSecondInstanceHandler();
    var launches = 0;
    final sub = shell.secondLaunches.listen((_) => launches++);
    addTearDown(sub.cancel);

    await _send(const MethodCall('focus'));
    await _send(const MethodCall('somethingElse'));

    expect(launches, 1);
  });

  test('an unrelated method on the same channel is ignored', () async {
    final port = FakeDesktopWindowPort();
    shell = shellFor(port);
    shell.registerSecondInstanceHandler();

    await _send(const MethodCall('somethingElse'));

    expect(port.showCalls, 0);
    expect(port.restoreCalls, 0);
  });

  test('a link call hands the link on and leaves raising the window to the '
      'focus call the runner sends after it', () async {
    final port = FakeDesktopWindowPort();
    shell = shellFor(port);
    shell.registerSecondInstanceHandler();
    final links = <Uri>[];
    final sub = shell.forwardedLinks.listen(links.add);
    addTearDown(sub.cancel);

    await _send(
      const MethodCall('link', 'slimm://spotify-callback?code=c&state=s'),
    );

    expect(links, [Uri.parse('slimm://spotify-callback?code=c&state=s')]);
    expect(port.showCalls, 0);
    expect(port.restoreCalls, 0);
  });

  test('a link call with another scheme or no text is dropped', () async {
    shell = shellFor(FakeDesktopWindowPort());
    shell.registerSecondInstanceHandler();
    final links = <Uri>[];
    final sub = shell.forwardedLinks.listen(links.add);
    addTearDown(sub.cancel);

    await _send(const MethodCall('link', 'https://example.com/x'));
    await _send(const MethodCall('link'));

    expect(links, isEmpty);
  });

  test('a port that throws leaves nothing uncaught', () async {
    final port = _ThrowingShowPort();
    shell = shellFor(port);
    shell.registerSecondInstanceHandler();

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
