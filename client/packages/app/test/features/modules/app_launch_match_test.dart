// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/providers/app_launch.dart';

const _apps = [
  api.App(
    moduleId: 'game-of-life',
    command: 'life',
    name: 'Game of Life',
    description: null,
  ),
];

void main() {
  test('matches an app by its module id', () {
    expect(matchApp(_apps, '/game-of-life')?.moduleId, 'game-of-life');
  });

  test('matches an app by its display name slugified, case-insensitively', () {
    expect(matchApp(_apps, '/Game-Of-Life')?.moduleId, 'game-of-life');
  });

  test('ignores any argument after the keyword: an app takes none', () {
    expect(matchApp(_apps, '/game-of-life whatever')?.moduleId, 'game-of-life');
  });

  test('no match for a non-slash message or an unknown keyword', () {
    expect(matchApp(_apps, 'game-of-life'), isNull);
    expect(matchApp(_apps, '/nope'), isNull);
    expect(matchApp(_apps, '/'), isNull);
    expect(matchApp(const [], '/game-of-life'), isNull);
  });

  test(
    'a module id wins over another app whose display name slugifies to it',
    () {
      // Impostor first, the way the server lists newest installs first.
      const impostor = api.App(
        moduleId: 'totally-different-id',
        command: 'run',
        name: 'Game Of Life',
        description: null,
      );
      const real = api.App(
        moduleId: 'game-of-life',
        command: 'life',
        name: 'Conway',
        description: null,
      );

      expect(
        matchApp(const [impostor, real], '/game-of-life')?.moduleId,
        'game-of-life',
        reason:
            'an app renders a live shared surface, so a display name must never '
            'take another app\'s launch keyword',
      );
    },
  );

  test(
    'a display name still matches when no module id claims that keyword',
    () {
      const only = api.App(
        moduleId: 'some-id',
        command: 'run',
        name: 'Tempo Grid',
        description: null,
      );
      expect(matchApp(const [only], '/tempo-grid')?.moduleId, 'some-id');
    },
  );
}
