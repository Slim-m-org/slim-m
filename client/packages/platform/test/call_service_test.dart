// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

const _channelName = 'top.npcserver.slimm/calls';

void _mock(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), handler);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => _mock(null));

  test('a non-Android platform never touches the channel', () async {
    final service = CallService(isAndroid: false);
    await expectLater(
      service.update(const CallServiceState(call: true)),
      completes,
    );
  });

  test('forwards the state, and skips a repeat of it', () async {
    final calls = <MethodCall>[];
    _mock((call) async {
      calls.add(call);
      return null;
    });
    final service = CallService(isAndroid: true);

    await service.update(const CallServiceState(call: true));
    await service.update(const CallServiceState(call: true));
    await service.update(const CallServiceState(call: true, camera: true));
    await service.update(const CallServiceState());

    expect(calls.map((c) => c.method).toSet(), {'updateCallService'});
    expect(calls.map((c) => c.arguments).toList(), [
      {'call': true, 'camera': false, 'share': false},
      {'call': true, 'camera': true, 'share': false},
      {'call': false, 'camera': false, 'share': false},
    ]);
  });

  test('a missing native handler is swallowed', () async {
    final service = CallService(isAndroid: true);
    await expectLater(
      service.update(const CallServiceState(call: true)),
      completes,
    );
  });
}
