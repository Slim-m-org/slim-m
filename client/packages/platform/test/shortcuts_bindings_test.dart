// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `resolveBindings` overlays a user's shortcut overrides on the defaults, and
/// two rules make it correct: an override must *replace* the default key for
/// its action rather than leave both bound (or the old key still fires it), and
/// an override to null must unbind the action entirely, which is how someone on
/// a screen reader or alternative input turns a shortcut off.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  serverSwitchShortcutTests();

  test('with no overrides the defaults are all present', () {
    final resolved = resolveBindings();
    expect(resolved.values, contains(AppAction.quickSwitch));
    expect(resolved.values, contains(AppAction.escape));
  });

  test('an override replaces the default key for its action, not adds to it',
      () {
    const custom = SingleActivator(LogicalKeyboardKey.f9);
    final resolved = resolveBindings(
      overrides: {AppAction.quickSwitch: custom},
    );

    expect(resolved[custom], AppAction.quickSwitch);
    expect(
      resolved.values.where((a) => a == AppAction.quickSwitch),
      hasLength(1),
      reason: 'the default key must be dropped, not left bound alongside',
    );
  });

  test('an override to null unbinds the action entirely', () {
    final resolved = resolveBindings(
      overrides: {AppAction.quickSwitch: null},
    );
    expect(resolved.values, isNot(contains(AppAction.quickSwitch)));
  });
}

void serverSwitchShortcutTests() {
  group('server switch shortcuts', () {
    test('are Ctrl or Cmd plus 1 to 9 and collide with nothing else', () {
      final activators = serverSwitchActivators(forWeb: false);
      expect(activators, hasLength(9));
      final taken = defaultBindings(forWeb: false).keys.toSet();
      for (final activator in activators) {
        expect(taken, isNot(contains(activator)));
      }
      expect(activators.toSet(), hasLength(9));
    });

    test('are left to the browser on the web build', () {
      expect(serverSwitchActivators(forWeb: true), isEmpty);
    });
  });
}
