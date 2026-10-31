// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the app hands the native badge bridge, and that other platforms never
/// reach it.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

const _name = 'top.npcserver.slimm/app_badge';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel(_name),
        (call) async {
      calls.add(call);
      return null;
    });
  });

  test('iOS sends the count and the read channels', () async {
    await AppBadgeChannel(isIOS: true)
        .sync(count: 3, readChannelIds: ['a', 'b']);
    expect(calls.single.method, 'sync');
    expect(calls.single.arguments, {
      'count': 3,
      'readChannelIds': ['a', 'b'],
    });
  });

  test('every other platform stays silent', () async {
    await AppBadgeChannel(isIOS: false).sync(count: 3, readChannelIds: ['a']);
    expect(calls, isEmpty);
  });

  test('a missing native side is swallowed', () async {
    messenger.setMockMethodCallHandler(const MethodChannel(_name), null);
    await AppBadgeChannel(isIOS: true).sync(count: 1, readChannelIds: []);
  });
}
