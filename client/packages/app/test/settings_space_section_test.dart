// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space settings screen must be gated on what `GET /me` actually
/// reports, not shown and left to answer 403: a caller with none of the
/// gating bits should see the screen render nothing at all, and a caller
/// with one bit should see only the row that bit unlocks.
///
/// Where personal and Space settings sit relative to each other, and that
/// neither leaks into the other, is `settings_taxonomy_test.dart`. Which
/// entry point reaches which screen, and that the rail hides the Space menu
/// entirely under the same gating, is `settings_entry_points_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/widgets/settings_notice.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_harness.dart';

void main() {
  setUpAll(mockAppVersion);

  testWidgets('an ordinary member with none of the gating bits sees a stated '
      'reason and not one gated row', (tester) async {
    await pumpSpaceSettings(tester, 0);

    expect(
      find.byType(SettingsNotice),
      findsOneWidget,
      reason:
          'this used to render nothing at all, which is a bare app bar over '
          'a blank page; see decision 0013',
    );
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('Reports'), findsNothing);
    expect(find.text('Invites'), findsNothing);
    expect(find.text('Roles'), findsNothing);
    expect(find.text('Channel permissions'), findsNothing);
    expect(find.text('Who can join'), findsNothing);
    expect(find.text('Emoji'), findsNothing);
    expect(find.text('Account recovery'), findsNothing);
  });

  testWidgets('MANAGE_MESSAGES alone unlocks only the reports row', (
    tester,
  ) async {
    await pumpSpaceSettings(tester, Perm.manageMessages);

    expect(find.widgetWithText(AppListRow, 'Reports'), findsOneWidget);
    expect(find.text('Invites'), findsNothing);
    expect(find.text('Roles'), findsNothing);
    expect(find.text('Channel permissions'), findsNothing);
  });

  testWidgets('CREATE_INVITE alone unlocks only the invites row', (
    tester,
  ) async {
    await pumpSpaceSettings(tester, Perm.createInvite);

    expect(find.widgetWithText(AppListRow, 'Invites'), findsOneWidget);
    expect(find.text('Reports'), findsNothing);
    expect(find.text('Roles'), findsNothing);
    expect(find.text('Channel permissions'), findsNothing);
  });

  testWidgets(
    'MANAGE_ROLES alone unlocks both the roles and channel permissions '
    'rows together, since one screen sets up targets the other edits',
    (tester) async {
      await pumpSpaceSettings(tester, Perm.manageRoles);

      expect(find.widgetWithText(AppListRow, 'Roles'), findsOneWidget);
      expect(find.text('Channel permissions'), findsOneWidget);
      expect(find.text('Reports'), findsNothing);
      expect(find.text('Invites'), findsNothing);
    },
  );

  /// MANAGE_SERVER is the bit the emoji endpoints themselves enforce
  /// (`require_manage_server` in `crates/slimm-server/src/http/emoji.rs`), so
  /// it is the bit the row is gated on. It unlocks nothing else: a caller who
  /// can change what the deployment is cannot thereby read the report queue.
  /// Who can join moved into the Invites pane, so MANAGE_SERVER now reaches
  /// that pane too - otherwise a role holding it without CREATE_INVITE would
  /// have lost the setting entirely. The invite half inside stays gated on
  /// CREATE_INVITE; only the policy row shows here.
  testWidgets('MANAGE_SERVER alone unlocks the emoji and invites rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpSpaceSettings(tester, Perm.manageServer);

    expect(find.text('Emoji'), findsOneWidget);
    expect(find.text('Invites'), findsOneWidget);
    expect(find.text('Reports'), findsNothing);
    expect(find.text('Roles'), findsNothing);
    expect(find.text('Channel permissions'), findsNothing);
    expect(
      find.text('Account recovery'),
      findsNothing,
      reason: 'MANAGE_SERVER opens most of Space settings but not this one',
    );
  });

  testWidgets('MANAGE_ROLES does not bring the emoji row with it', (
    tester,
  ) async {
    await pumpSpaceSettings(tester, Perm.manageRoles);

    expect(find.text('Emoji'), findsNothing);
  });

  /// The server resolves ADMINISTRATOR into every bit before `/me` ever
  /// answers (see `evaluate()`'s bypass in permissions.rs), so the wire value
  /// a real administrator's client receives already has every bit set; this
  /// mock mirrors that resolved value rather than sending the lone
  /// ADMINISTRATOR bit and asking the client to re-derive the bypass itself,
  /// which it deliberately does not do.
  testWidgets('an administrator sees every row', (tester) async {
    await pumpSpaceSettings(tester, allPermissionBits);

    expect(find.widgetWithText(AppListRow, 'Reports'), findsOneWidget);
    expect(find.text('Invites'), findsOneWidget);
    expect(find.text('Roles'), findsOneWidget);
    expect(find.text('Channel permissions'), findsOneWidget);
    expect(find.text('Emoji'), findsOneWidget);
    expect(find.text('Account recovery'), findsOneWidget);
  });

  /// The screen used to zero out its own padding, which sat its bare rows
  /// flush against the edges of the content column - a tighter margin than
  /// any personal settings pane, whose `ListView` keeps the scaffold's
  /// default `s16` on every side. An embedded pane inherits that default
  /// through `SettingsPane.padding`; pinned on one that does not override it,
  /// since nothing else here would fail if the default regressed to zero.
  testWidgets('an embedded pane keeps the same outer padding a personal '
      'settings pane uses, not zero', (tester) async {
    await pumpSpaceSettings(tester, allPermissionBits);
    await tester.tap(find.text('Removed members'));
    await tester.pumpAndSettle();

    final paneList = find.descendant(
      of: find.byType(AppFadeIn),
      matching: find.byType(ListView),
    );
    final listView = tester.widget<ListView>(paneList);
    expect(listView.padding, const EdgeInsets.fromLTRB(32, 24, 32, 40));
  });
}
