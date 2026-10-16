// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's optional `changelog`: parsed defensively, and sliced by what a
/// space already has installed.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, dynamic> _manifest([Object? changelog = _absent]) => {
      'id': 'dice',
      'name': 'Dice',
      'version': '0.1.3',
      'summary': 's',
      'artifact': {'kind': 'wasm', 'path': 'p', 'sha256': 'a'},
      'runtime': {
        'backend': 'wasm',
        'limits': {'memory_mb': 64, 'wall_ms': 2000, 'fuel': 1},
      },
      'permissions': <Object>[],
      'capabilities': <Object>[],
      'extension_points': <Object>[],
      if (changelog != _absent) 'changelog': changelog,
    };

const _absent = Object();

const _three = [
  {
    'version': '0.1.3',
    'changes': ['c'],
  },
  {
    'version': '0.1.2',
    'changes': ['b'],
  },
  {
    'version': '0.1.10',
    'changes': ['older by string order only'],
  },
];

List<String> _versions(List<DockChangelogEntry> e) => [
      for (final x in e) x.version,
    ];

void main() {
  group('changelog parsing', () {
    test('absent is empty', () {
      expect(DockManifest.fromJson(_manifest()).changelog, isEmpty);
    });

    test('a non-list is empty', () {
      expect(DockManifest.fromJson(_manifest('nope')).changelog, isEmpty);
    });

    test('entries without a string version or a list are dropped', () {
      final m = DockManifest.fromJson(
        _manifest([
          'text',
          {'version': 3, 'changes': <Object>[]},
          {'version': '1.0.0'},
          {
            'version': '0.9.0',
            'changes': ['kept', 4, null],
          },
        ]),
      );
      expect(m.changelog, hasLength(1));
      expect(m.changelog.single.version, '0.9.0');
      expect(m.changelog.single.changes, ['kept']);
    });
  });

  group('changesSince', () {
    final m = DockManifest.fromJson(_manifest(_three));

    test('not installed: the newest entry only', () {
      expect(_versions(m.changesSince(null)), ['0.1.10']);
    });

    test('installed older: every entry newer than it', () {
      expect(_versions(m.changesSince('0.1.1')), ['0.1.10', '0.1.3', '0.1.2']);
      expect(_versions(m.changesSince('0.1.2')), ['0.1.10', '0.1.3']);
    });

    test('up to date: nothing', () {
      expect(m.changesSince('0.1.10'), isEmpty);
      expect(m.changesSince('1.0.0'), isEmpty);
    });

    test('non-numeric versions fall back to equality', () {
      final odd = DockManifest.fromJson(
        _manifest([
          {
            'version': 'beta-2',
            'changes': ['x'],
          },
          {
            'version': 'beta-1',
            'changes': ['y'],
          },
        ]),
      );
      expect(_versions(odd.changesSince('beta-1')), ['beta-2']);
    });

    test('an unlisted non-numeric installed version yields only the newest',
        () {
      expect(_versions(m.changesSince('nightly')), ['0.1.10']);
    });

    test('an unsorted changelog is returned newest first', () {
      final unsorted = DockManifest.fromJson(
        _manifest([
          {
            'version': '0.1.2',
            'changes': ['a'],
          },
          {
            'version': '0.1.10',
            'changes': ['b'],
          },
          {
            'version': '0.1.3',
            'changes': ['c'],
          },
        ]),
      );
      expect(_versions(unsorted.changesSince('0.1.0')), [
        '0.1.10',
        '0.1.3',
        '0.1.2',
      ]);
      expect(_versions(unsorted.changesSince(null)), ['0.1.10']);
    });

    test('empty changelog stays empty', () {
      expect(DockManifest.fromJson(_manifest()).changesSince('0.1.0'), isEmpty);
      expect(DockManifest.fromJson(_manifest()).changesSince(null), isEmpty);
    });
  });

  test('compareDockVersions compares integer parts', () {
    expect(compareDockVersions('0.1.10', '0.1.9'), 1);
    expect(compareDockVersions('1.0', '1.0.0'), 0);
    expect(compareDockVersions('0.2.0', '0.10.0'), -1);
    expect(compareDockVersions('a', '1'), isNull);
  });
}
