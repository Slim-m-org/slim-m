// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The taskbar flash and badge reach the runner's channel on Windows only.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(taskbarAttentionChannelName);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  });

  test('a Windows host sends flash, stop and badge to the runner', () async {
    final taskbar = TaskbarAttention(isWindows: true);

    await taskbar.flash();
    await taskbar.stop();
    await taskbar.setBadge(3);
    await taskbar.setBadge(-2);

    expect(calls.map((c) => c.method), ['flash', 'stop', 'badge', 'badge']);
    expect(calls[2].arguments, 3);
    expect(calls[3].arguments, 0, reason: 'a negative count clears the badge');
  });

  test('any other host never reaches the channel', () async {
    final taskbar = TaskbarAttention(isWindows: false);

    await taskbar.flash();
    await taskbar.stop();
    await taskbar.setBadge(3);

    expect(calls, isEmpty);
  });

  test('a runner without the channel is not an error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    await expectLater(TaskbarAttention(isWindows: true).flash(), completes);
  });
}
