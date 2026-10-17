// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasSelfPresenceController]: the default state, that hiding persists
/// to `SharedPreferences`, and that a fresh controller (a relaunch, or
/// reopening the canvas) reads a previously persisted value back instead of
/// the default.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_self_presence.dart';

/// A second container over the same mocked prefs store, modelling a
/// relaunch (or reopening the canvas): nothing carries state forward except
/// what was written to (mocked) disk. Awaiting the fresh controller's own
/// [CanvasSelfPresenceController.ready] is what makes this deterministic -
/// no guessing how many event-loop turns a `SharedPreferences` round trip
/// takes.
Future<ProviderContainer> _relaunch() async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await container.read(canvasSelfPresenceProvider.notifier).ready;
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to visible, with nothing stored', () async {
    final container = await _relaunch();

    expect(container.read(canvasSelfPresenceProvider).hidden, isFalse);
  });

  test('setHidden persists, and a later launch reads it back', () async {
    final first = ProviderContainer();
    addTearDown(first.dispose);
    await first.read(canvasSelfPresenceProvider.notifier).setHidden(true);
    expect(first.read(canvasSelfPresenceProvider).hidden, isTrue);

    final relaunch = await _relaunch();
    expect(relaunch.read(canvasSelfPresenceProvider).hidden, isTrue);
  });

  test('setHidden(false) reverses it, and that also persists', () async {
    final first = ProviderContainer();
    addTearDown(first.dispose);
    await first.read(canvasSelfPresenceProvider.notifier).setHidden(true);
    await first.read(canvasSelfPresenceProvider.notifier).setHidden(false);

    final relaunch = await _relaunch();
    expect(relaunch.read(canvasSelfPresenceProvider).hidden, isFalse);
  });

  test('hiding right after construction is not clobbered by a load already in '
      'flight', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(canvasSelfPresenceProvider.notifier);

    // Nothing is stored, so the in-flight load would answer `false`; this call must win.
    await notifier.setHidden(true);
    await notifier.ready;

    expect(container.read(canvasSelfPresenceProvider).hidden, isTrue);
  });
}
