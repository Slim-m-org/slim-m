// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Linux launcher count and the activation token a banner click carries.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/linux_desktop_bus_io.dart';

void main() {
  group('LinuxLauncherCount', () {
    test('never opens the session bus until main enables it', () async {
      await LinuxLauncherCount().set(5);

      expect(linuxLauncherBusOpened, isFalse);
    });

    test('the default activation token source is silent until enabled',
        () async {
      final token = LinuxActivationToken()..listen();

      expect(token.take(), isNull);
    });

    test('emits a count once and again only when it changes', () async {
      final sent = <int>[];
      final count = LinuxLauncherCount(emit: (n) async => sent.add(n));

      await count.set(3);
      await count.set(3);
      await count.set(0);

      expect(sent, [3, 0]);
    });

    test('a negative count shows as zero', () async {
      final sent = <int>[];
      await LinuxLauncherCount(emit: (n) async => sent.add(n)).set(-4);

      expect(sent, [0]);
    });

    test('a failing session bus never throws into the caller', () async {
      final count = LinuxLauncherCount(emit: (_) => throw StateError('no bus'));

      await count.set(1);
    });
  });

  group('LinuxActivationToken', () {
    test('hands over the newest token once', () async {
      final source = StreamController<String>();
      final token = LinuxActivationToken(tokens: source.stream)..listen();

      source
        ..add('old')
        ..add('new');
      await pumpEventQueue();

      expect(token.take(), 'new');
      expect(token.take(), isNull);
    });

    test('a token older than its lifetime is dropped', () async {
      final source = StreamController<String>();
      var now = DateTime(2026);
      final token = LinuxActivationToken(
        tokens: source.stream,
        clock: () => now,
      )..listen();

      source.add('stale');
      await pumpEventQueue();
      now = now.add(activationTokenLifetime + const Duration(seconds: 1));

      expect(token.take(), isNull);
    });

    test('a stream error leaves the listener alive', () async {
      final source = StreamController<String>();
      final token = LinuxActivationToken(tokens: source.stream)..listen();

      source.addError(StateError('bus gone'));
      source.add('after');
      await pumpEventQueue();

      expect(token.take(), 'after');
    });
  });
}
