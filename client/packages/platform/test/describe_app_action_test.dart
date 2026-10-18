// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shortcut hints read from the bindings the app actually listens for.
///
/// A hint naming a key the app does not listen for is worse than no hint, and
/// the empty channel pane now shows several of them at once. Deriving the
/// labels from `activatorFor`'s own resolved table is what keeps a remap and
/// its hint from drifting apart.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  test('the primary modifier and its key, in press order', () {
    final keys = describeAppAction(AppAction.quickSwitch, forWeb: false);
    expect(keys.length, 2);
    expect(keys.first, anyOf('Ctrl', 'Cmd'));
    expect(keys.last, 'K');
  });

  test('a key with no printable label still gets a name', () {
    // Tab would otherwise fall through to a debug string.
    expect(describeAppAction(AppAction.nextChannel, forWeb: false),
        contains('Tab'));
    expect(describeAppAction(AppAction.openSettings, forWeb: false),
        contains(','));
  });

  test('the inbox has its own key, shared with no other action', () {
    final keys = describeAppAction(AppAction.openInbox, forWeb: false);

    expect(keys, containsAll(['Shift', 'I']));
    final owners = resolveBindings(forWeb: false).values;
    expect(owners.where((a) => a == AppAction.openInbox), hasLength(1));
  });

  test('the web build describes its own browser-safe keys', () {
    // Ctrl+Tab never reaches the page, so the hint must not claim it does.
    final keys = describeAppAction(AppAction.nextChannel, forWeb: true);
    expect(keys, contains('Alt'));
    expect(keys, contains('Down'));
    expect(keys, isNot(contains('Tab')));
  });

  test('shift is named for the action that carries it', () {
    expect(
      describeAppAction(AppAction.previousChannel, forWeb: false),
      contains('Shift'),
    );
  });

  test('an override that removes a binding describes nothing', () {
    // A cleared binding shows no row rather than an empty keycap.
    expect(
      describeAppAction(
        AppAction.quickSwitch,
        overrides: const {AppAction.quickSwitch: null},
        forWeb: false,
      ),
      isEmpty,
    );
  });

  test('an override is described instead of the default', () {
    final keys = describeAppAction(
      AppAction.quickSwitch,
      overrides: const {
        AppAction.quickSwitch: SingleActivator(
          LogicalKeyboardKey.keyJ,
          alt: true,
        ),
      },
      forWeb: false,
    );
    expect(keys, ['Alt', 'J']);
  });
}
