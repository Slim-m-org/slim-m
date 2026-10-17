// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Personal settings is a nav beside a pane now, not nine sections in one
/// scroll, so what is worth pinning has changed with it.
///
/// The old version checked the *order* of section headers down a single
/// column, which was the right thing to check while a column was all there
/// was. What matters here instead is the taxonomy: that every category is
/// reachable, that a pane shows only its own content, and that neither
/// settings screen leaks the other's.
///
/// That last one is not cosmetic. Personal settings renders for every signed
/// in caller regardless of permission, and Space settings is hidden entirely
/// for a caller holding none of its gating bits; anything from the second
/// appearing on the first would be a permission leak rather than a layout slip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_account_sections.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_harness.dart';

/// Every nav entry the personal screen offers, and the group it sits under.
const List<(String?, String)> _panes = [
  ('You', 'Profile'),
  ('You', 'Account & devices'),
  ('App', 'Appearance'),
  ('App', 'Notifications'),
  ('App', 'Voice & screen share'),
  ('App', 'General'),
  ('Safety', 'Blocked'),
  ('Safety', 'Report status'),
  ('Help', 'Troubleshooting'),
  ('Help', 'About slim-m'),
];

const _spaceRows = [
  'Reports',
  'Invites',
  'Roles',
  'Channel permissions',
  'Who can join',
  'Emoji',
  'Account recovery',
];

/// The wide nav sets group names in capitals; the compact menu's card headers do not.
Finder _heading(String group) =>
    find.textContaining(RegExp('^$group\$', caseSensitive: false));

void main() {
  setUpAll(mockAppVersion);

  testWidgets('every category is reachable, under its own group heading', (
    tester,
  ) async {
    useTallViewport(tester);
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);

    for (final (group, pane) in _panes) {
      if (group != null) {
        expect(_heading(group), findsWidgets, reason: group);
      }
      expect(find.text(pane), findsOneWidget, reason: pane);
    }
  });

  /// Every group is named, the trailing one included. `About slim-m` used to
  /// sit under a bare gap on the theory that a heading over one row is
  /// decoration; the owner read that gap as a section missing its header,
  /// so the rule is now the simpler one: a divider always comes with a name.
  testWidgets('every group has a heading, the last one included', (
    tester,
  ) async {
    useTallViewport(tester);
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);

    for (final (group, pane) in _panes) {
      expect(group, isNotNull, reason: '$pane sits under an unnamed group');
      expect(_heading(group!), findsWidgets, reason: group);
    }
  });

  testWidgets('devices live with the account, not in a pane of their own', (
    tester,
  ) async {
    useTallViewport(tester);
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);
    expect(find.text('Devices'), findsNothing, reason: 'no nav row');
    await tester.tap(find.text('Account & devices'));
    await tester.pumpAndSettle();
    expect(find.text('Devices'), findsOneWidget, reason: 'a section header');
  });

  /// A pane whose whole body is one card must not title that card with the
  /// name its pane heading already gives it: "Appearance" under "Appearance"
  /// is a header carrying no information, which is the case decision 0013
  /// made `SettingsSectionCard.title` nullable for. The heading itself is the
  /// pane's name at two-pane width, so the nav row is no longer its only
  /// occurrence.
  ///
  /// `Blocked` is the deliberate exception and is absent from this list: its
  /// header earns the repeat by carrying a real description under it.
  testWidgets('a single-card pane does not restate its own name', (
    tester,
  ) async {
    // Two-pane width: the restatement only shows with nav and pane together.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 2400);
    addTearDown(tester.view.reset);
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);

    for (final label in [
      'Profile',
      'Appearance',
      'Notifications',
      'About slim-m',
    ]) {
      await tester.tap(find.widgetWithText(AppListRow, label));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(SettingsSectionHeader, label),
        findsNothing,
        reason:
            'the pane heading names the pane once; a section header repeating '
            '"$label" under it says nothing the heading has not already said',
      );
    }
  });

  testWidgets('the delete warning survives, above the action', (tester) async {
    useTallViewport(tester);
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);
    await tester.tap(find.text('Account & devices'));
    await tester.pumpAndSettle();

    expect(
      find.text(accountDeletionDescription),
      findsOneWidget,
      reason:
          'moving this off the row must not drop it: it is the whole warning '
          'on the most consequential action in personal settings',
    );
  });

  testWidgets('deleting the account is not filed under About', (tester) async {
    useTallViewport(tester);
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);

    await tester.tap(find.text('About slim-m'));
    await tester.pumpAndSettle();
    expect(
      find.text('Delete account...'),
      findsNothing,
      reason:
          'permanent and irreversible, so it does not hide behind a pane '
          'whose name promises a version number',
    );
  });

  testWidgets('the nav is the same whoever is looking', (tester) async {
    useTallViewport(tester);
    await pumpPersonalSettings(
      tester,
      allPermissionBits,
      scrollToBottom: false,
    );

    // Nothing here is permission-gated, so an admin sees the same list.
    for (final (_, pane) in _panes) {
      expect(find.text(pane), findsOneWidget, reason: pane);
    }
  });

  testWidgets('signing out is on the frame, not inside a category', (
    tester,
  ) async {
    useTallViewport(tester);
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);

    // Present without opening anything, and deletion is not beside it.
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Delete account...'), findsNothing);
  });

  testWidgets('personal settings never shows Space content', (tester) async {
    useTallViewport(tester);
    await pumpPersonalSettings(
      tester,
      allPermissionBits,
      scrollToBottom: false,
    );

    for (final row in _spaceRows) {
      expect(
        find.text(row),
        findsNothing,
        reason: '$row leaked onto personal settings',
      );
    }
  });

  testWidgets('Space settings never shows personal content', (tester) async {
    await pumpSpaceSettings(tester, allPermissionBits);

    for (final (_, pane) in _panes) {
      expect(find.text(pane), findsNothing, reason: '$pane leaked onto Space');
    }
    expect(find.text('Version'), findsNothing);
  });
}
