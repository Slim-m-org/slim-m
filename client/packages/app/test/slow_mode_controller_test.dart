// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pure arithmetic behind the composer's slow-mode countdown: see
/// `composer_slow_mode_test.dart` for what `Composer` does with the number
/// this produces.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/slow_mode_controller.dart';

void main() {
  final base = DateTime.utc(2026, 1, 1, 12);

  test('off (0 seconds) is always 0, regardless of when last sent', () {
    expect(
      slowModeRemainingSeconds(slowModeSeconds: 0, lastSentAt: base, now: base),
      0,
    );
  });

  test('never having sent here is always 0', () {
    expect(
      slowModeRemainingSeconds(
        slowModeSeconds: 30,
        lastSentAt: null,
        now: base,
      ),
      0,
    );
  });

  test('immediately after sending, the full interval remains', () {
    expect(
      slowModeRemainingSeconds(
        slowModeSeconds: 10,
        lastSentAt: base,
        now: base,
      ),
      10,
    );
  });

  test('partway through the window, the remainder rounds up', () {
    // 4200ms elapsed of a 10s window leaves 5800ms, which rounds up to 6s rather than truncating to 5.
    expect(
      slowModeRemainingSeconds(
        slowModeSeconds: 10,
        lastSentAt: base,
        now: base.add(const Duration(milliseconds: 4200)),
      ),
      6,
    );
  });

  test('once the interval has fully elapsed, it is 0', () {
    expect(
      slowModeRemainingSeconds(
        slowModeSeconds: 10,
        lastSentAt: base,
        now: base.add(const Duration(seconds: 10)),
      ),
      0,
    );
  });

  test('past the interval is also 0, not negative', () {
    expect(
      slowModeRemainingSeconds(
        slowModeSeconds: 10,
        lastSentAt: base,
        now: base.add(const Duration(seconds: 30)),
      ),
      0,
    );
  });

  group('SlowModeLastSent', () {
    test('records a channel independently of others', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(slowModeLastSentProvider.notifier).recordSent('c1', base);

      expect(container.read(slowModeLastSentProvider), {'c1': base});
    });

    test('an older timestamp never overwrites a newer one', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final later = base.add(const Duration(seconds: 5));
      final notifier = container.read(slowModeLastSentProvider.notifier);
      notifier.recordSent('c1', later);
      notifier.recordSent('c1', base);

      expect(
        container.read(slowModeLastSentProvider)['c1'],
        later,
        reason: 'a delayed echo of an older send must not rewind the clock',
      );
    });
  });
}
