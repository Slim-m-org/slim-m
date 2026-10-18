// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [DesktopWindowShell.registerListenersAndTray] must never leave
/// `main.dart`'s bootstrap stuck: a thrown error or a hang in the native
/// window/tray plumbing has to be logged and swallowed, not left to strand
/// the caller - `appReadyProvider` only ever flips once this future
/// resolves, and the startup screen it gates has no timeout of its own.
///
/// [DesktopWindowShell.applyInitialGeometry] carries the same obligation for
/// the same reason, and more sharply: it runs before `runApp`, so a hang
/// there blocks the very first frame from ever painting, not a later ready
/// flip - the strictly worse silent-forever screen.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';

import 'support/fake_desktop_window_port.dart';

class _ThrowingPort extends FakeDesktopWindowPort {
  @override
  Future<void> ensureInitialized() async {
    throw StateError('no native window here');
  }
}

class _ThrowsLatePort extends FakeDesktopWindowPort {
  @override
  Future<void> setPreventClose(bool value) async {
    throw StateError('close interception unavailable');
  }
}

class _HangingPort extends FakeDesktopWindowPort {
  @override
  Future<void> ensureInitialized() => Completer<void>().future;
}

ProviderContainer _container() {
  final container = ProviderContainer();
  AppLog.install(container.read(debugLogProvider.notifier));
  addTearDown(() {
    AppLog.install(null);
    container.dispose();
  });
  return container;
}

bool _loggedFromDesktop(ProviderContainer container) => container
    .read(debugLogProvider)
    .any((event) => event.source == LogTag.platform);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DesktopWindowShell.debugReset();
  });
  tearDown(DesktopWindowShell.debugReset);

  test('a port that throws immediately is logged and swallowed, not left to '
      'strand the caller', () async {
    final container = _container();
    DesktopWindowShell.debugPort = _ThrowingPort();

    await DesktopWindowShell.registerListenersAndTray(container);

    expect(DesktopWindowShell.active, isTrue);
    expect(DesktopWindowShell.frameless, isFalse);
    expect(_loggedFromDesktop(container), isTrue);
  });

  test('a port that throws partway through setup is also swallowed, not just '
      'a failure on the first call', () async {
    final container = _container();
    DesktopWindowShell.debugPort = _ThrowsLatePort();

    await DesktopWindowShell.registerListenersAndTray(container);

    expect(DesktopWindowShell.active, isTrue);
    expect(_loggedFromDesktop(container), isTrue);
  });

  test('a port that never completes setup is given up on after the timeout, '
      'not waited on forever', () {
    fakeAsync((async) {
      final container = _container();
      DesktopWindowShell.debugPort = _HangingPort();

      var completed = false;
      unawaited(
        DesktopWindowShell.registerListenersAndTray(
          container,
        ).whenComplete(() => completed = true),
      );
      async.flushMicrotasks();
      expect(completed, isFalse);

      async.elapse(const Duration(seconds: 5));
      expect(completed, isTrue);
      expect(_loggedFromDesktop(container), isTrue);
    });
  });

  test('applyInitialGeometry gives up on a hanging native call after the '
      'timeout, so a stuck portal at launch cannot block the first frame', () {
    fakeAsync((async) {
      DesktopWindowShell.debugPort = _HangingPort();

      var completed = false;
      unawaited(
        DesktopWindowShell.applyInitialGeometry().whenComplete(
          () => completed = true,
        ),
      );
      async.flushMicrotasks();
      expect(completed, isFalse);

      async.elapse(const Duration(seconds: 5));
      expect(completed, isTrue);
    });
  });

  test('applyInitialGeometry swallows a throwing native call rather than '
      'letting it strand main() before runApp', () async {
    DesktopWindowShell.debugPort = _ThrowingPort();

    await DesktopWindowShell.applyInitialGeometry();
  });
}
