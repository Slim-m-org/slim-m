// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The last five themes applied here: every apply records one, a file or a
/// choice that is not one theme never does, and an entry that can no longer
/// be applied drops out of view.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/recent_themes.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/providers/theme_store.dart';
import 'package:slimm_app/src/features/settings/providers/theme_store_actions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

ThemeDocument _doc(String name, {ThemePicture? picture}) => ThemeDocument.of(
  AppTokens.forest,
  name: name,
  author: 'Ren',
  base: 'forest',
  brightness: Brightness.dark,
  picture: picture,
);

Map<String, dynamic> _listed(String id) => {
  'id': id,
  'name': 'Pine',
  'author_id': 'ren',
  'author_name': 'Ren',
  'created_at': 1,
  'has_picture': false,
  'theme': _doc('Pine').toJson(),
};

ProviderContainer _container({Future<api.SpaceThemeList>? store}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      spaceThemesProvider.overrideWith(
        (ref) => store ?? Completer<api.SpaceThemeList>().future,
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

List<String> _keys(List<RecentTheme> recent) => [
  for (final r in recent) r.source.key,
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('every apply puts its theme first, once, five at most', (
    tester,
  ) async {
    final container = _container();
    late WidgetRef ref;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, r, _) {
            ref = r;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await tester.runAsync(() async {
      for (final choice in [
        AppThemeChoice.dark,
        AppThemeChoice.light,
        AppThemeChoice.forest,
      ]) {
        await applyThemeChoice(ref, choice);
      }
      await applyThemeDocument(
        ref,
        _doc('Moss'),
        source: const MineThemeSource('m1'),
      );
      await applyThemeDocument(
        ref,
        _doc('Pine'),
        source: const SpaceThemeSource('t1'),
      );
      await applyThemeChoice(ref, AppThemeChoice.dark);
    });
    expect(_keys(container.read(recentThemesProvider)), [
      'builtin:dark',
      'space:t1',
      'mine:m1',
      'builtin:forest',
      'builtin:light',
    ]);

    await tester.runAsync(() async {
      await applyThemeChoice(ref, AppThemeChoice.softDark);
      await applyThemeChoice(ref, AppThemeChoice.spaceDefault);
      await applyThemeDocument(
        ref,
        _doc('Loose'),
        source: const FileThemeSource(),
      );
    });
    expect(_keys(container.read(recentThemesProvider)), [
      'builtin:softDark',
      'builtin:dark',
      'space:t1',
      'mine:m1',
      'builtin:forest',
    ]);
    expect(container.read(customThemeSourceProvider), const FileThemeSource());
  });

  test('a Space entry keeps its file but not the picture data', () async {
    final container = _container();
    final picture = ThemePicture(
      dim: 0.4,
      vignette: true,
      blur: 0.2,
      data: Uint8List.fromList([1, 2, 3]),
    );
    await container
        .read(recentThemesProvider.notifier)
        .record(
          const SpaceThemeSource('t1'),
          theme: _doc('Pine', picture: picture),
        );
    await container
        .read(recentThemesProvider.notifier)
        .record(const MineThemeSource('m1'), theme: _doc('Moss'));

    final recent = container.read(recentThemesProvider);
    expect(recent.first.theme, isNull, reason: 'Mine keeps no copy');
    final space = recent.last.theme!;
    expect(space.name, 'Pine');
    expect(space.picture!.data, isNull);
    expect(space.picture!.dim, 0.4);

    final restarted = _container();
    await restarted.read(recentThemesProvider.notifier).restore();
    final restored = restarted.read(recentThemesProvider);
    expect(_keys(restored), ['mine:m1', 'space:t1']);
    expect(restored.last.theme!.name, 'Pine');
  });

  test('a stored list with junk in it keeps what it can read', () async {
    SharedPreferences.setMockInitialValues({
      recentThemesKey:
          '[{"source":"builtin:dark"},{"source":"file"},{"source":"nope"},'
          '{"source":"space:t1"},{"source":"builtin:dark"},7]',
    });
    final container = _container();
    await container.read(recentThemesProvider.notifier).restore();

    expect(_keys(container.read(recentThemesProvider)), ['builtin:dark']);
  });

  test(
    'a deleted Mine theme and a dropped Space theme leave the view',
    () async {
      final store = Completer<api.SpaceThemeList>();
      final container = _container(store: store.future);
      container.listen(shownRecentThemesProvider, (_, _) {});
      final id = (await container
          .read(myThemesProvider.notifier)
          .save(_doc('Moss')))!;
      final recents = container.read(recentThemesProvider.notifier);
      await recents.record(const SpaceThemeSource('gone'), theme: _doc('Old'));
      await recents.record(const SpaceThemeSource('t1'), theme: _doc('Pine'));
      await recents.record(MineThemeSource(id));
      await recents.record(const BuiltInThemeSource(AppThemeChoice.forest));

      expect(_keys(container.read(shownRecentThemesProvider)), [
        'builtin:forest',
        'mine:$id',
        'space:t1',
        'space:gone',
      ], reason: 'a store still loading hides nothing');

      store.complete(
        api.SpaceThemeList.fromJson({
          'themes': [_listed('t1')],
          'default_theme_id': null,
        }),
      );
      await container.read(spaceThemesProvider.future);
      await container.read(myThemesProvider.notifier).remove(id);

      expect(_keys(container.read(shownRecentThemesProvider)), [
        'builtin:forest',
        'space:t1',
      ]);
      expect(container.read(recentThemesProvider), hasLength(4));
    },
  );
}
