// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Block and Unblock are opposite actions and used to share one glyph
/// (`AppIcons.revoke`), which drew "Block" and "Unblock" identically in the
/// same popover. Split out of `member_profile_test.dart` to keep that file
/// under the 300-line review budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';
import '../../support/fake_blocks.dart';

const _other = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
);

Widget _harness(Widget child, {Set<String> blocked = const {}}) =>
    ProviderScope(
      overrides: [
        myPermissionsProvider.overrideWithValue(0),
        membersProvider.overrideWith((ref) async => const []),
        blocksProvider.overrideWith(
          (ref) => FixedBlocksController(
            ref,
            BlocksState(ids: blocked, settled: true),
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: RepaintBoundary(key: snapshotBoundary, child: child),
        ),
      ),
    );

Widget _body(api.UserProfile profile) =>
    MemberProfileBody(profile: profile, compact: false, onDone: () {});

void main() {
  setUpAll(loadRealFonts);

  testWidgets('an unblocked member gets Block on the revoke glyph', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_body(_other)));
    await tester.pump();

    expect(find.text('Block'), findsOneWidget);
    expect(find.text('Unblock'), findsNothing);
    expect(find.widgetWithIcon(AppMenuItem, AppIcons.revoke), findsOneWidget);
    expect(
      find.widgetWithIcon(AppMenuItem, AppIcons.restoreAccess),
      findsNothing,
    );
    await writeSnapshot(tester, 'member-profile-block-row');
  });

  testWidgets(
    'a blocked member gets Unblock on its own glyph, never the ban icon',
    (tester) async {
      await tester.pumpWidget(_harness(_body(_other), blocked: {_other.id}));
      await tester.pump();

      expect(find.text('Unblock'), findsOneWidget);
      expect(find.text('Block'), findsNothing);
      expect(
        find.widgetWithIcon(AppMenuItem, AppIcons.restoreAccess),
        findsOneWidget,
      );
      expect(
        find.widgetWithIcon(AppMenuItem, AppIcons.revoke),
        findsNothing,
        reason:
            'Block and Unblock are opposite actions; sharing a glyph draws '
            'them identically in the same menu',
      );
      await writeSnapshot(tester, 'member-profile-unblock-row');
    },
  );
}
