// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The lifecycle the app actually reads, built by its provider over the
/// window port, follows what the port reports and what the window answers.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';

import '../desktop/support/desktop_shell_fixture.dart';
import '../desktop/support/fake_desktop_window_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDesktopWindowPort port;
  late ProviderContainer container;

  AppLifecycleState lifecycle() => container.read(appLifecycleProvider);

  /// The fake's stream is asynchronous, as the plugin's is.
  Future<void> send(DesktopWindowEventKind kind) async {
    port.emit(kind);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    port = FakeDesktopWindowPort();
    container = ProviderContainer(
      overrides: [
        desktopWindowShellProvider.overrideWithValue(shellFor(port)),
        mobileLifecycleHostProvider.overrideWithValue(false),
      ],
    );
    container.listen(appLifecycleProvider, (_, _) {});
  });

  tearDown(() {
    container.dispose();
    final binding = WidgetsBinding.instance;
    while (binding.lifecycleState != AppLifecycleState.resumed) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });

  test('a window the compositor stopped painting reads as hidden', () async {
    expect(lifecycle(), AppLifecycleState.resumed);

    port.suspendedByCompositor = true;
    await send(DesktopWindowEventKind.suspend);
    expect(lifecycle(), AppLifecycleState.hidden);

    port.suspendedByCompositor = false;
    await send(DesktopWindowEventKind.unsuspend);
    expect(lifecycle(), AppLifecycleState.resumed);
  });

  test('a focus on a minimised window asks the window first', () async {
    port.minimized = true;
    await send(DesktopWindowEventKind.minimize);
    await send(DesktopWindowEventKind.focus);

    expect(port.isMinimizedCalls, 1);
    expect(lifecycle(), AppLifecycleState.hidden);

    port.minimized = false;
    await send(DesktopWindowEventKind.show);
    expect(lifecycle(), AppLifecycleState.resumed);
  });

  test('a window that fails to answer is believed to have the focus', () async {
    port.minimizedQueryError = PlatformException(code: 'channel-error');
    await send(DesktopWindowEventKind.minimize);
    await send(DesktopWindowEventKind.focus);

    expect(port.isMinimizedCalls, 1);
    expect(lifecycle(), AppLifecycleState.resumed);
  });
}
