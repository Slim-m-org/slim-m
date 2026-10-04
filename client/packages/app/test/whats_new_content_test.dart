// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pure version-compare and entry-selection logic behind the
/// what's-new sheet, tested with no widget, provider or platform channel
/// involved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/whats_new/whats_new_content.dart';

void main() {
  group('compareVersions', () {
    test('orders numerically, not lexically', () {
      expect(compareVersions('0.9.0', '0.10.0'), lessThan(0));
      expect(compareVersions('0.10.0', '0.9.0'), greaterThan(0));
    });

    test('equal versions compare equal', () {
      expect(compareVersions('0.17.2', '0.17.2'), 0);
    });

    test('a missing trailing segment reads as zero', () {
      expect(compareVersions('0.17', '0.17.0'), 0);
      expect(compareVersions('0.17', '0.17.1'), lessThan(0));
    });

    test('a pre-release or build suffix is ignored for ordering', () {
      expect(compareVersions('0.17.2-beta.1', '0.17.2'), 0);
      expect(compareVersions('0.17.2+42', '0.17.2'), 0);
    });

    test(
      'a segment that will not parse reads as zero rather than throwing',
      () {
        expect(() => compareVersions('0.x.2', '0.0.2'), returnsNormally);
        expect(compareVersions('0.x.2', '0.0.2'), 0);
      },
    );
  });

  group('pendingWhatsNewEntries', () {
    test('a null lastSeen returns every entry up to currentVersion', () {
      // The newest shipped entry, or a new entry breaks this every release.
      final pending = pendingWhatsNewEntries(
        lastSeen: null,
        currentVersion: whatsNewEntries.last.version,
      );
      expect(pending, whatsNewEntries);
    });

    test('an entry newer than currentVersion is excluded', () {
      final pending = pendingWhatsNewEntries(
        lastSeen: null,
        currentVersion: '0.1.0',
      );
      expect(pending, isEmpty);
    });

    test('lastSeen at or after every entry returns nothing', () {
      final pending = pendingWhatsNewEntries(
        lastSeen: '0.17.2',
        currentVersion: '0.17.2',
      );
      expect(pending, isEmpty);
    });

    test(
      'only entries strictly after lastSeen, up to current, are returned',
      () {
        const seen = WhatsNewEntry(
          version: '0.16.0',
          headline: 'seen already',
          points: [WhatsNewPoint('already shown')],
        );
        const unseen = WhatsNewEntry(
          version: '0.18.0',
          headline: 'not shown yet',
          points: [WhatsNewPoint('new')],
        );
        const tooNew = WhatsNewEntry(
          version: '0.20.0',
          headline: 'not released yet',
          points: [WhatsNewPoint('future')],
        );
        // A fixture, not the module's live `whatsNewEntries`, which grows.
        final pending = pendingWhatsNewEntries(
          lastSeen: '0.17.0',
          currentVersion: '0.18.5',
          entries: [seen, unseen, tooNew],
        );
        expect(pending, [unseen]);
      },
    );
  });

  group('whatsNewEntries assembly', () {
    // Guards the archive split (five archive files plus the live one) against a move that drops, duplicates, or reorders an entry.
    test('every entry sorts strictly after the one before it', () {
      for (var i = 1; i < whatsNewEntries.length; i++) {
        final previous = whatsNewEntries[i - 1].version;
        final current = whatsNewEntries[i].version;
        expect(
          compareVersions(current, previous),
          greaterThan(0),
          reason:
              'entry $current at index $i must sort strictly after $previous; '
              'this fails on a duplicated version, a version out of order, '
              'or the same entry appearing in two of the split files',
        );
      }
    });

    test('has every entry from all six archives plus the live file', () {
      // Bump alongside every new entry; a move across the archive split must never change this on its own.
      expect(whatsNewEntries.length, 67);
    });
  });
}
