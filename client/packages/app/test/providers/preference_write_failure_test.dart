// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A preference that cannot be read or written is logged and skipped, never
/// thrown into the caller or left to land on a disposed notifier.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_recent_colours.dart';
import 'package:slimm_app/src/providers/auto_update_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';

ProviderContainer _failingPrefs() {
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith((ref) async => throw StateError('full')),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a failed write still keeps the colour in memory', () async {
    final container = _failingPrefs();

    await container
        .read(canvasRecentColoursProvider.notifier)
        .remember('#aabbcc');

    expect(container.read(canvasRecentColoursProvider), ['#aabbcc']);
  });

  test('a failed preference read keeps auto-update on', () async {
    final container = _failingPrefs();
    final sub = container.listen(autoUpdateProvider, (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(autoUpdateProvider), isTrue);
  });
}
