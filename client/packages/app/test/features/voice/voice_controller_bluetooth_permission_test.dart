// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call asks for the Bluetooth grant before the session starts routing
/// audio, and a denial still joins.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/bluetooth_permission_provider.dart';
import 'package:slimm_platform/platform.dart';

import 'voice_controller_harness.dart';

class _FakeBluetooth extends BluetoothPermissionChannel {
  _FakeBluetooth(this.session, {required this.granted});

  final FakeSession session;
  final bool granted;
  final joinedWhenAsked = <bool?>[];

  @override
  Future<bool> request() async {
    joinedWhenAsked.add(session.joinedAbleToPublish);
    return granted;
  }
}

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  for (final granted in [true, false]) {
    test(
      'asks before the session joins and joins when granted is $granted',
      () async {
        final session = FakeSession();
        final bluetooth = _FakeBluetooth(session, granted: granted);
        final controller = harness.controllerWith(
          session,
          voiceApi(),
          extraOverrides: [
            bluetoothPermissionProvider.overrideWithValue(bluetooth),
          ],
        );

        await controller.join('channel-1');

        expect(bluetooth.joinedWhenAsked, [null]);
        expect(session.joinedAbleToPublish, isNotNull);
        expect(controller.state.error, isNull);
      },
    );
  }

  group('askBluetoothBeforeJoin', () {
    test('does not wait on a dialog that never answers', () {
      fakeAsync((async) {
        var done = false;
        askBluetoothBeforeJoin(_HungBluetooth()).then((_) => done = true);
        async.elapse(bluetoothAskLimit);
        expect(done, isTrue);
      });
    });

    test('does not ask while the app is in the background', () async {
      final bluetooth = _HungBluetooth();
      await askBluetoothBeforeJoin(
        bluetooth,
        lifecycle: AppLifecycleState.paused,
      );
      expect(bluetooth.asked, 0);
    });

    test('asks while the app is in front', () async {
      final bluetooth = _CountingBluetooth();
      await askBluetoothBeforeJoin(
        bluetooth,
        lifecycle: AppLifecycleState.resumed,
      );
      expect(bluetooth.asked, 1);
    });
  });
}

class _HungBluetooth extends BluetoothPermissionChannel {
  int asked = 0;

  @override
  Future<bool> request() {
    asked++;
    return Completer<bool>().future;
  }
}

class _CountingBluetooth extends BluetoothPermissionChannel {
  int asked = 0;

  @override
  Future<bool> request() async {
    asked++;
    return true;
  }
}
