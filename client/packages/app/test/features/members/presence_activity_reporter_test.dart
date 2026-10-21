// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Owner report: "a user is still marked as online even though their computer
/// has been asleep and not touched in 8 hours". The reporter sends `active`
/// only while the person is really here, so an untouched client goes away.
library;

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/presence_activity_reporter.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_platform/platform.dart';

import '../../support/fake_sync.dart';

class _FakeIdle implements SystemIdle {
  Duration? idle;

  @override
  Duration? idleTime() => idle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int sent;
  late bool inCall;
  late _FakeIdle systemIdle;

  PresenceActivityReporter reporter({SystemIdle? idle}) =>
      PresenceActivityReporter(
        send: () {
          sent++;
          return true;
        },
        inCall: () => inCall,
        systemIdle: idle,
      )..start();

  setUp(() {
    sent = 0;
    inCall = false;
    systemIdle = _FakeIdle();
  });

  test('an untouched device sends nothing, however long it runs', () {
    fakeAsync((async) {
      final r = reporter();
      async.elapse(const Duration(hours: 8));
      expect(sent, 0);
      expect(r.here(), isFalse);
      r.dispose();
    }, initialTime: DateTime(2026, 10, 19));
  });

  test('input reports at once, then about once a minute while it lasts', () {
    fakeAsync((async) {
      final r = reporter();
      r.noteInput();
      expect(sent, 1, reason: 'coming back must clear away without a wait');
      for (var i = 0; i < 600; i++) {
        async.elapse(const Duration(milliseconds: 500));
        r.noteInput();
      }
      expect(sent, inInclusiveRange(5, 11));
      final before = sent;
      async.elapse(const Duration(minutes: 20));
      expect(sent - before, lessThanOrEqualTo(1));
      r.dispose();
    }, initialTime: DateTime(2026, 10, 19));
  });

  test('input in another app counts where the host reports it', () {
    fakeAsync((async) {
      final r = reporter(idle: systemIdle);
      systemIdle.idle = const Duration(seconds: 5);
      async.elapse(const Duration(minutes: 3));
      expect(sent, 3);
      systemIdle.idle = const Duration(minutes: 30);
      async.elapse(const Duration(minutes: 3));
      expect(sent, 3);
      r.dispose();
    }, initialTime: DateTime(2026, 10, 19));
  });

  test('being in a call counts as here', () {
    fakeAsync((async) {
      final r = reporter();
      inCall = true;
      async.elapse(const Duration(minutes: 2));
      expect(sent, 2);
      expect(r.here(), isTrue);
      r.dispose();
    }, initialTime: DateTime(2026, 10, 19));
  });

  test('here() answers the hello after a wake from sleep', () {
    withClock(Clock.fixed(DateTime(2026, 10, 19)), () {
      final r = PresenceActivityReporter(send: () => true, inCall: () => false);
      expect(r.here(), isFalse);
      r.noteInput();
      expect(r.here(), isTrue);
    });
  });

  test('a reconnect after minutes of reading still claims here', () {
    fakeAsync((async) {
      final r = PresenceActivityReporter(send: () => true, inCall: () => false);
      r.noteInput();
      async.elapse(const Duration(minutes: 5));
      expect(r.here(), isFalse);
      expect(r.hereAtHello(), isTrue);
      async.elapse(const Duration(minutes: 5));
      expect(r.hereAtHello(), isFalse);
    }, initialTime: DateTime(2026, 10, 19));
  });

  test('a frame no live socket took does not use up the throttle', () {
    var live = false;
    var taken = 0;
    final r = PresenceActivityReporter(
      send: () {
        if (live) taken++;
        return live;
      },
      inCall: () => false,
    );
    r.noteInput();
    live = true;
    r.noteInput();
    expect(taken, 1);
  });

  test('the provider wires the hello claim and the active frames', () async {
    late _RecordingSync sync;
    final container = ProviderContainer(
      overrides: [
        syncControllerProvider.overrideWith(
          (ref) => sync = _RecordingSync(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(presenceActivityReporterProvider);
    expect(sync.activeAtHello, isNotNull);
    expect(sync.activeAtHello!(), isFalse, reason: 'untouched');
    container.read(presenceActivityReporterProvider).noteInput();
    expect(sync.actives, 1);
    expect(sync.activeAtHello!(), isTrue);
    withClock(
      Clock.fixed(clock.now().add(const Duration(minutes: 5))),
      () => expect(sync.activeAtHello!(), isTrue, reason: 'inside the window'),
    );
    container.dispose();
  });
}

class _RecordingSync extends NoopSyncController {
  _RecordingSync(super.ref);

  int actives = 0;

  @override
  bool notifyActive() {
    actives++;
    return true;
  }
}
