// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A hand-driven global hotkey source for the global hotkey suites.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'dart:async';

import 'package:slimm_platform/platform.dart';

class FakeHotkeySource implements GlobalHotkeySource {
  FakeHotkeySource({
    this.probeResult = const GlobalHotkeyAvailability.available(
      'Works when slim-m is in the background.',
    ),
  });

  final GlobalHotkeyAvailability probeResult;
  final binds = <List<GlobalHotkeyId>>[];
  final chords = <List<HotkeyChord>>[];
  final _events = StreamController<GlobalHotkeyEvent>.broadcast();

  @override
  Stream<GlobalHotkeyEvent> get events => _events.stream;

  @override
  Future<GlobalHotkeyAvailability> probe() async => probeResult;

  @override
  Future<GlobalHotkeyAvailability> bind(
    List<GlobalHotkeyBinding> bindings,
  ) async {
    binds.add([for (final b in bindings) b.id]);
    chords.add([for (final b in bindings) b.chord]);
    return probeResult;
  }

  void send(GlobalHotkeyId id, GlobalHotkeyPhase phase) =>
      _events.add(GlobalHotkeyEvent(id, phase));

  void lose() => _events.add(const GlobalHotkeyEvent.lost());

  @override
  Future<void> dispose() async {}
}
