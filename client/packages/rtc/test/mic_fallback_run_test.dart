// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a microphone fallback run does when the call ends under it, when the
/// host cannot pick a microphone, and when the new level cannot be read.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/voice_session_mic_fallback.dart';

const _usb = AudioDevice(id: 'usb', label: 'USB headset');
const _desk = AudioDevice(id: 'desk', label: 'Desk mic');

class _Devices implements AudioDevices {
  @override
  Future<List<AudioDevice>> inputs() async => const [_usb, _desk];
  @override
  Future<List<AudioDevice>> outputs() async => const [];
  @override
  Future<AudioDevice?> systemDefaultInput() async => null;
  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;
  @override
  Stream<void> get onChange => const Stream.empty();
}

class _Switching extends AudioDeviceSwitching {
  _Switching({required this.canPick}) : super(_Devices());
  final bool canPick;
  @override
  bool get supportsInputSelection => canPick;
}

class _Mic extends Fake implements MicPort {
  double? level = -30;
  @override
  Future<double?> senderLevelDb() async => level;
}

class _Rig {
  _Rig({bool canPick = true}) : switching = _Switching(canPick: canPick) {
    fallback = MicFallback(
      MicFallbackHost(
        switching: () => switching,
        hasRoom: () => room,
        micWanted: () => wanted,
        mic: () => mic,
        timing: () => const MicRecoveryTiming(
          fallbackSettle: Duration(seconds: 1),
        ),
        watchdog: () => SilentMicWatchdog(
          timing: const MicRecoveryTiming(),
          onSilent: () {},
        ),
        log: (m, {level = LogLevel.info}) => logs.add(m),
        setStatus: statuses.add,
        noteFailure: (_) async {},
        restartCapture: (_) async => restarted,
        selectInput: (d) async {
          picks.add(d?.id);
          await switching.selectInput(null, d, remember: false);
          return true;
        },
        selectOutput: (_) async => true,
      ),
    );
  }

  final _Switching switching;
  final mic = _Mic();
  late final MicFallback fallback;
  final logs = <String>[];
  final statuses = <MicStatus>[];
  final picks = <String?>[];
  bool room = true;
  bool wanted = true;
  bool restarted = true;
}

void main() {
  test('a host that cannot pick a microphone switches nothing', () {
    fakeAsync((clock) {
      final rig = _Rig(canPick: false);

      rig.fallback.run();
      clock.elapse(const Duration(seconds: 10));

      expect(rig.picks, isEmpty);
      expect(rig.statuses, isEmpty);
      expect(rig.logs.single, contains('cannot pick a microphone'));
    });
  });

  test('a call that ends mid-run gets no status, notice or further switch', () {
    fakeAsync((clock) {
      final rig = _Rig()..mic.level = -30;

      rig.fallback.run();
      clock.elapse(const Duration(milliseconds: 500));
      expect(rig.picks, hasLength(1));
      rig.room = false;
      rig.fallback.reset();
      clock.elapse(const Duration(seconds: 10));

      expect(rig.picks, hasLength(1));
      expect(rig.statuses, isEmpty);
      expect(rig.fallback.notice, isNull);
      expect(
          rig.logs, isNot(contains(startsWith('Microphone fallback worked'))));
    });
  });

  test('a run for the next call is not dropped while the last one unwinds', () {
    fakeAsync((clock) {
      final rig = _Rig();

      rig.fallback.run();
      clock.elapse(const Duration(milliseconds: 500));
      expect(rig.picks, hasLength(1));
      rig.fallback.reset();
      rig.fallback.run();
      clock.elapse(const Duration(milliseconds: 100));

      expect(rig.picks, hasLength(2));
    });
  });

  test('muting mid-run does not report a success', () {
    fakeAsync((clock) {
      final rig = _Rig();

      rig.fallback.run();
      clock.elapse(const Duration(milliseconds: 500));
      rig.wanted = false;
      clock.elapse(const Duration(seconds: 10));

      expect(rig.statuses, isEmpty);
      expect(rig.fallback.notice, isNull);
    });
  });

  test('a capture that will not reopen is a failed candidate', () {
    fakeAsync((clock) {
      final rig = _Rig()..restarted = false;

      rig.fallback.run();
      clock.elapse(const Duration(seconds: 10));

      expect(rig.picks, hasLength(2));
      expect(rig.statuses, [MicStatus.unavailable]);
      expect(rig.fallback.notice, isNull);
    });
  });

  test('a level that cannot be read is kept but not called a success', () {
    fakeAsync((clock) {
      final rig = _Rig()..mic.level = null;

      rig.fallback.run();
      clock.elapse(const Duration(seconds: 10));

      expect(rig.picks, hasLength(1));
      expect(rig.statuses, isEmpty);
      expect(rig.logs, contains(contains('could not be verified')));
      expect(
          rig.logs, isNot(contains(startsWith('Microphone fallback worked'))));
    });
  });

  test('a silent candidate moves on to the next', () {
    fakeAsync((clock) {
      final rig = _Rig()..mic.level = kInputFloorDb;

      rig.fallback.run();
      clock.elapse(const Duration(seconds: 10));

      expect(rig.picks.toSet(), {'usb', 'desk'});
      expect(rig.statuses, [MicStatus.unavailable]);
    });
  });
}
