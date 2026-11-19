// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Wayland minimise reaches the app only as the compositor's suspended
/// state, which the Linux runner forwards over its own channel.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/linux_window_suspended.dart';

/// What the runner does when GDK reports the window obscured or not.
Future<void> _runnerSays(bool suspended) => TestDefaultBinaryMessengerBinding
    .instance
    .defaultBinaryMessenger
    .handlePlatformMessage(
      linuxWindowSuspendedChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('suspendedChanged', suspended),
      ),
      (_) {},
    );

void _runnerStartsWith({required bool suspended}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    linuxWindowSuspendedChannel,
    (call) async => call.method == 'isSuspended' ? suspended : null,
  );
  addTearDown(
    () => messenger.setMockMethodCallHandler(linuxWindowSuspendedChannel, null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the runner reporting suspended reaches the port as events', () async {
    _runnerStartsWith(suspended: false);
    final port = WindowManagerDesktopWindowPort();
    final seen = <DesktopWindowEventKind>[];
    final sub = port.events.listen(seen.add);
    addTearDown(sub.cancel);
    await watchLinuxWindowSuspended(port.onCompositorSuspended);
    expect(port.suspendedByCompositor, isFalse);

    await _runnerSays(true);
    expect(port.suspendedByCompositor, isTrue);
    await _runnerSays(false);
    expect(port.suspendedByCompositor, isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [
      DesktopWindowEventKind.suspend,
      DesktopWindowEventKind.unsuspend,
    ]);
  });

  test('a window already suspended when the app starts is known', () async {
    _runnerStartsWith(suspended: true);
    final port = WindowManagerDesktopWindowPort();

    await watchLinuxWindowSuspended(port.onCompositorSuspended);

    expect(port.suspendedByCompositor, isTrue);
  });

  test('a runner with no such channel leaves the window visible', () async {
    final port = WindowManagerDesktopWindowPort();

    await watchLinuxWindowSuspended(port.onCompositorSuspended);

    expect(port.suspendedByCompositor, isFalse);
  });

  test(
    'a Linux window starts listening to the runner when it initializes',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const plugin = MethodChannel('window_manager');
      messenger.setMockMethodCallHandler(plugin, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(plugin, null));
      _runnerStartsWith(suspended: false);
      final port = WindowManagerDesktopWindowPort();

      await port.ensureInitialized();
      await _runnerSays(true);

      expect(port.suspendedByCompositor, isTrue);
    },
    skip: Platform.isLinux ? false : 'the runner channel exists only on Linux',
  );

  test('a minimised window is never asked while it cannot answer', () {
    final port = WindowManagerDesktopWindowPort();

    expect(port.isMinimized, throwsA(isA<WindowNotQueryable>()));
  });
}
