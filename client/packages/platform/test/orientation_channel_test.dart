// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/orientation');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('asks native and reports what it answered', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    final changed = await OrientationChannel(
      channel: channel,
    ).allowLandscape(true);

    expect(changed, isTrue);
    expect(calls.single.method, 'allowLandscape');
    expect(calls.single.arguments, true);
  });

  test('nothing answering reads as unchanged, never a throw', () async {
    expect(
      await OrientationChannel(channel: channel).allowLandscape(true),
      isFalse,
    );
  });
}
