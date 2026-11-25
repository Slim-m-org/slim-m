// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A banner click on Linux presents the window under the server's activation token.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/linux_window_presenter.dart';
import 'package:slimm_platform/platform.dart';

import 'support/desktop_shell_fixture.dart';
import 'support/fake_desktop_window_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/present');
  final presented = <Object?>[];

  setUp(() {
    presented.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          presented.add(call.arguments);
          return true;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  LinuxWindowPresenter presenterWith(Stream<String> tokens) =>
      LinuxWindowPresenter(
        channel: channel,
        tokens: LinuxActivationToken(tokens: tokens),
      )..start();

  test('presents with the token the server sent for the click', () async {
    final tokens = StreamController<String>();
    final presenter = presenterWith(tokens.stream);

    tokens.add('xdg-token');
    await pumpEventQueue();

    expect(await presenter.present(), isTrue);
    expect(presented, ['xdg-token']);
  });

  test('without a token it presents nothing', () async {
    final presenter = presenterWith(const Stream.empty());

    expect(await presenter.present(), isFalse);
    expect(presented, isEmpty);
  });

  test('raising on Linux presents before showing the window', () async {
    final tokens = StreamController<String>();
    final port = FakeDesktopWindowPort();
    final shell = shellFor(
      port,
      chrome: DesktopPlatform.linux,
      presenter: presenterWith(tokens.stream),
    );
    tokens.add('xdg-token');
    await pumpEventQueue();

    await shell.raise();

    expect(presented, ['xdg-token']);
    expect(port.showCalls, 1);
  });
}
