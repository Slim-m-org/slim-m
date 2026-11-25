// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  const channel = MethodChannel('top.npcserver.slimm/app_lock_window');

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  test('releasing the cover reaches the native side', () async {
    await AppLockWindowChannel(channel: channel, supported: true, isIOS: true)
        .releasePrivacyShield();
    expect(calls.single.method, 'releasePrivacyShield');
  });

  test('releasing the cover is silent where nothing answers', () async {
    await AppLockWindowChannel(channel: channel, supported: false)
        .releasePrivacyShield();
    expect(calls, isEmpty);
  });

  test('releasing the cover is not sent on Android', () async {
    await AppLockWindowChannel(channel: channel, supported: true, isIOS: false)
        .releasePrivacyShield();
    expect(calls, isEmpty);
  });
}
