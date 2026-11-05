// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Mine": themes kept on this device survive a restart, and replace in place.
library;

import 'dart:ui' show Brightness;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_design_system/design_system.dart';

ThemeDocument _doc(String name, {ThemePicture? picture}) => ThemeDocument.of(
  AppTokens.forest,
  name: name,
  author: '',
  base: 'forest',
  brightness: Brightness.dark,
  picture: picture,
);

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a saved theme is restored by a new container', () async {
    final first = _container();
    final id = await first.read(myThemesProvider.notifier).save(_doc('Pine'));

    final second = _container();
    await second.read(myThemesProvider.notifier).restore();
    final restored = second.read(myThemesProvider);
    expect(restored.map((t) => t.id), [id]);
    expect(restored.single.document.toJson(), _doc('Pine').toJson());
  });

  test('saving under an id replaces that entry and keeps its place', () async {
    final container = _container();
    final notifier = container.read(myThemesProvider.notifier);
    final a = await notifier.save(_doc('A'));
    await notifier.save(_doc('B'));
    await notifier.save(_doc('A renamed'), id: a);

    expect(container.read(myThemesProvider).map((t) => t.document.name), [
      'A renamed',
      'B',
    ]);
  });

  test('a picture is not kept', () async {
    final container = _container();
    await container
        .read(myThemesProvider.notifier)
        .save(
          _doc(
            'Pic',
            picture: const ThemePicture(dim: 0.5, vignette: true, blur: 0),
          ),
        );
    expect(container.read(myThemesProvider).single.document.picture, isNull);
  });

  test('remove forgets a theme', () async {
    final container = _container();
    final notifier = container.read(myThemesProvider.notifier);
    final id = await notifier.save(_doc('Gone'));
    await notifier.remove(id!);
    expect(container.read(myThemesProvider), isEmpty);

    final fresh = _container();
    await fresh.read(myThemesProvider.notifier).restore();
    expect(fresh.read(myThemesProvider), isEmpty);
  });

  test('the device keeps at most $myThemesMax', () async {
    final container = _container();
    final notifier = container.read(myThemesProvider.notifier);
    for (var i = 0; i < myThemesMax; i++) {
      expect(await notifier.save(_doc('T$i')), isNotNull);
    }
    expect(await notifier.save(_doc('One too many')), isNull);
    expect(container.read(myThemesProvider), hasLength(myThemesMax));
  });

  test('an entry that no longer parses is dropped on restore', () async {
    SharedPreferences.setMockInitialValues({
      myThemesKey:
          '[{"id":"x","theme":{"format":"nope"}},'
          '{"id":"y","theme":${_doc('Fine').toJsonText()}}]',
    });
    final container = _container();
    await container.read(myThemesProvider.notifier).restore();
    expect(container.read(myThemesProvider).map((t) => t.id), ['y']);
  });

  test('unreadable storage leaves none', () async {
    SharedPreferences.setMockInitialValues({myThemesKey: 'not json'});
    final container = _container();
    await container.read(myThemesProvider.notifier).restore();
    expect(container.read(myThemesProvider), isEmpty);
  });
}
