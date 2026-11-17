// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the theme in use came from: stored with the custom slot when it is
/// applied, inferred for an install that never stored one, and read as Not
/// saved once its Mine or Space entry is gone.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/providers/theme_store.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

ThemeDocument _doc(String name, {AppTokens tokens = AppTokens.forest}) =>
    ThemeDocument.of(
      tokens,
      name: name,
      author: 'Ren',
      base: 'forest',
      brightness: Brightness.dark,
    );

Map<String, dynamic> _listed(String id, ThemeDocument document) => {
  'id': id,
  'name': document.name,
  'author_id': 'ren',
  'author_name': 'Ada',
  'created_at': 1,
  'has_picture': false,
  'theme': document.toJson(),
};

/// A container with the Space store answering [themes]; null never loads it.
ProviderContainer _container({
  List<Map<String, dynamic>>? themes,
  String? defaultId,
}) {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      spaceThemesProvider.overrideWith(
        (ref) => themes == null
            ? Completer<api.SpaceThemeList>().future
            : Future.value(
                api.SpaceThemeList.fromJson({
                  'themes': themes,
                  'default_theme_id': defaultId,
                }),
              ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(appliedThemeProvider, (_, _) {});
  return container;
}

Future<AppliedTheme> _applied(ProviderContainer c) async {
  await c
      .read(spaceThemesProvider.future)
      .timeout(
        const Duration(milliseconds: 50),
        onTimeout: () => api.SpaceThemeList.fromJson({'themes': <Object?>[]}),
      );
  return c.read(appliedThemeProvider);
}

Future<void> _useCustom(
  ProviderContainer c,
  ThemeDocument document, [
  ThemeSource? source,
]) async {
  await c.read(customThemeProvider.notifier).set(document);
  if (source != null) {
    await c.read(customThemeSourceProvider.notifier).set(source);
  }
  await c.read(themeControllerProvider.notifier).select(AppThemeChoice.custom);
}

void main() {
  test('every key reads back as the source it was written from', () {
    const sources = <ThemeSource>[
      BuiltInThemeSource(AppThemeChoice.forest),
      MineThemeSource('m1'),
      SpaceThemeSource('t1'),
      FileThemeSource(),
    ];
    for (final source in sources) {
      expect(ThemeSource.parse(source.key), source, reason: source.key);
    }
    expect(const BuiltInThemeSource(AppThemeChoice.dark).key, 'builtin:dark');
    for (final unknown in ['builtin:neon', 'mine:', 'shared:t1', 'files']) {
      expect(ThemeSource.parse(unknown), isNull, reason: unknown);
    }
  });

  test('a built-in choice is its own source', () async {
    final c = _container(themes: const []);
    await c.read(themeControllerProvider.notifier).select(AppThemeChoice.light);

    final applied = await _applied(c);
    expect(applied.source, const BuiltInThemeSource(AppThemeChoice.light));
    expect(applied.following, isFalse);
  });

  test('following a Space with a default reads as that Space theme', () async {
    final c = _container(
      themes: [_listed('t1', _doc('Pine'))],
      defaultId: 't1',
    );
    await c
        .read(themeControllerProvider.notifier)
        .select(AppThemeChoice.spaceDefault);

    final applied = await _applied(c);
    expect(applied.following, isTrue);
    expect(applied.source, const SpaceThemeSource('t1'));
    expect(applied.document!.name, 'Pine');
    expect(applied.author, 'Ada');
  });

  test('following a Space with no default paints System', () async {
    final c = _container(themes: [_listed('t1', _doc('Pine'))]);
    await c
        .read(themeControllerProvider.notifier)
        .select(AppThemeChoice.spaceDefault);

    final applied = await _applied(c);
    expect(applied.following, isFalse);
    expect(applied.source, const BuiltInThemeSource(AppThemeChoice.system));
  });

  test('a stored Mine source reads as Not saved once deleted', () async {
    final c = _container(themes: const []);
    final id = (await c.read(myThemesProvider.notifier).save(_doc('Moss')))!;
    await _useCustom(c, _doc('Moss'), MineThemeSource(id));
    expect((await _applied(c)).source, MineThemeSource(id));

    await c.read(myThemesProvider.notifier).remove(id);

    final applied = await _applied(c);
    expect(applied.source, const FileThemeSource());
    expect(applied.unsaved, isTrue);
    expect(applied.lost, MineThemeSource(id));
  });

  test('a Space source reads as Not saved once the store drops it', () async {
    final listed = _container(themes: [_listed('t1', _doc('Pine'))]);
    await _useCustom(listed, _doc('Pine'), const SpaceThemeSource('t1'));
    final kept = await _applied(listed);
    expect(kept.source, const SpaceThemeSource('t1'));
    expect(kept.author, 'Ada');

    final dropped = _container(themes: const []);
    await _useCustom(dropped, _doc('Pine'), const SpaceThemeSource('t1'));
    expect((await _applied(dropped)).source, const FileThemeSource());
  });

  test('a Space source keeps its place while the store is loading', () async {
    final c = _container();
    await _useCustom(c, _doc('Pine'), const SpaceThemeSource('t1'));

    expect(c.read(appliedThemeProvider).source, const SpaceThemeSource('t1'));
  });

  test(
    'with nothing stored the source is inferred from the file text',
    () async {
      final mine = _container(themes: [_listed('t1', _doc('Pine'))]);
      final id = (await mine
          .read(myThemesProvider.notifier)
          .save(_doc('Pine')))!;
      await _useCustom(mine, _doc('Pine'));
      expect((await _applied(mine)).source, MineThemeSource(id));

      final space = _container(themes: [_listed('t1', _doc('Pine'))]);
      await _useCustom(space, _doc('Pine'));
      expect((await _applied(space)).source, const SpaceThemeSource('t1'));

      final file = _container(themes: [_listed('t1', _doc('Pine'))]);
      await _useCustom(file, _doc('Bracken', tokens: AppTokens.mocha));
      final applied = await _applied(file);
      expect(applied.source, const FileThemeSource());
      expect(applied.unsaved, isTrue);
      expect(applied.lost, isNull);
    },
  );

  test('the stored source survives a restart', () async {
    final c = _container(themes: const []);
    await c
        .read(customThemeSourceProvider.notifier)
        .set(const SpaceThemeSource('t9'));

    final restarted = ProviderContainer(
      overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
    );
    addTearDown(restarted.dispose);
    await restarted.read(customThemeSourceProvider.notifier).restore();
    expect(
      restarted.read(customThemeSourceProvider),
      const SpaceThemeSource('t9'),
    );
  });
}
