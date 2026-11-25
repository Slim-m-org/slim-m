// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/bluetooth_permission');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('asks native and reports whether it was granted', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    final granted = await BluetoothPermissionChannel(
      channel: channel,
      supported: true,
    ).request();

    expect(granted, isTrue);
    expect(calls.single.method, 'request');
  });

  test('a denial reads as false', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    expect(
      await BluetoothPermissionChannel(channel: channel, supported: true)
          .request(),
      isFalse,
    );
  });

  test('nothing answering reads as denied, never a throw', () async {
    expect(
      await BluetoothPermissionChannel(channel: channel, supported: true)
          .request(),
      isFalse,
    );
  });

  test('a host with no native half never touches the channel', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return true;
    });
    expect(
      await BluetoothPermissionChannel(channel: channel, supported: false)
          .request(),
      isFalse,
    );
    expect(calls, 0);
  });
}
