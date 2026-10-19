// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the key-storage seam and the shortcut table.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

void main() {
  group('key store', () {
    late KeyStore store;
    setUp(() => store = InMemoryKeyStore());

    test('stores, reads back, and deletes', () async {
      final handle = await store.put('session', 'a-token');
      expect(await store.read(handle), 'a-token');
      await store.delete(handle);
      expect(await store.read(handle), isNull);
    });

    test('clear removes everything, for sign-out on a shared machine',
        () async {
      await store.put('a', '1');
      await store.put('b', '2');
      await store.clear();
      expect(await store.read('a'), isNull);
      expect(await store.read('b'), isNull);
    });

    test('signing is refused rather than faked', () async {
      // The seam exists so a hardware backend can implement sign() without
      // read(). A bogus signature here would hide that gap until it mattered.
      await store.put('identity', 'x');
      expect(
        () => store.sign('identity', [1, 2, 3]),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('shortcuts', () {
    test('every action has a human-readable label', () {
      // A keybinding screen has to name these; a missing label would show an
      // enum identifier to a user.
      for (final action in AppAction.values) {
        expect(action.label, isNotEmpty);
        expect(action.label, isNot(contains('AppAction')));
      }
    });

    test('defaults cover every action', () {
      final bound = defaultBindings().values.toSet();
      expect(bound, containsAll(AppAction.values));
    });

    test('an override replaces the default rather than adding to it', () {
      const custom = SingleActivator(LogicalKeyboardKey.keyJ, control: true);
      final resolved = resolveBindings(
        overrides: {AppAction.quickSwitch: custom},
      );

      expect(resolved[custom], AppAction.quickSwitch);
      // Exactly one binding for the action, so the old key no longer triggers it.
      final forQuickSwitch = resolved.entries
          .where((e) => e.value == AppAction.quickSwitch)
          .length;
      expect(forQuickSwitch, 1);
    });

    test('an override to null unbinds the action entirely', () {
      // Someone using an alternative input device may want a shortcut gone
      // rather than moved.
      final resolved = resolveBindings(
        overrides: {AppAction.quickSwitch: null},
      );
      expect(resolved.values, isNot(contains(AppAction.quickSwitch)));
      expect(resolved.values, contains(AppAction.focusComposer));
    });

    test('activatorFor finds the key currently bound to an action', () {
      // SingleActivator has no value equality, so a freshly resolved map's
      // key never `==` one from an earlier call; compare fields instead.
      final expected = resolveBindings()
          .entries
          .firstWhere((e) => e.value == AppAction.quickSwitch)
          .key as SingleActivator;
      final activator = activatorFor(AppAction.quickSwitch) as SingleActivator?;
      expect(activator, isNotNull);
      expect(activator!.trigger, expected.trigger);
      expect(activator.control, expected.control);
      expect(activator.meta, expected.meta);
      expect(activator.shift, expected.shift);
    });

    test('activatorFor returns null once the action is unbound', () {
      final activator = activatorFor(
        AppAction.quickSwitch,
        overrides: {AppAction.quickSwitch: null},
      );
      expect(activator, isNull);
    });

    /// Every browser reserves Ctrl+Tab (and Ctrl+Shift+Tab) to switch its
    /// own tabs, so the default binding would do nothing on the web build;
    /// `forWeb` cannot be read off the real `kIsWeb` here, since a VM test
    /// never runs as web, so it is passed explicitly.
    test('next/previous channel use a browser-safe key on the web build', () {
      final native =
          activatorFor(AppAction.nextChannel, forWeb: false) as SingleActivator;
      final web =
          activatorFor(AppAction.nextChannel, forWeb: true) as SingleActivator;

      expect(native.trigger, LogicalKeyboardKey.tab);
      expect(web.trigger, LogicalKeyboardKey.arrowDown);
      expect(web.alt, isTrue);
      expect(web.control, isFalse);
      expect(web.meta, isFalse);
    });

    test('the web binding still tells next and previous apart', () {
      final next =
          activatorFor(AppAction.nextChannel, forWeb: true) as SingleActivator;
      final previous = activatorFor(AppAction.previousChannel, forWeb: true)
          as SingleActivator;

      expect(next.trigger, LogicalKeyboardKey.arrowDown);
      expect(previous.trigger, LogicalKeyboardKey.arrowUp);
    });
  });
}
