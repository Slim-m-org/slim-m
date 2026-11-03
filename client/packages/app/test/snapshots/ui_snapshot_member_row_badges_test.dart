// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Member rows with a role chip and a module badge, at the 236px member pane
/// and a phone-width drawer, in both themes. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise each scene asserts it lays out cleanly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/module_badges.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_app/src/features/modules/providers/module_display_settings.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';

api.UserProfile _member(String id, String name, {List<String>? roles}) =>
    api.UserProfile(
      id: id,
      username: id,
      displayName: name,
      createdAt: 0,
      roleIds: roles == null ? const [] : const ['r-admin'],
      roles: roles ?? const [],
      statusText: id == 'nick' ? 'joinkin it' : null,
    );

api.ModuleBadge _level(String text) => api.ModuleBadge(
  moduleId: 'xp',
  name: 'level',
  item: api.ModuleSlotItem.parse({
    'nodes': [
      {'type': 'badge', 'text': text, 'tone': 'accent', 'icon': 'sparkles'},
    ],
  }),
);

class _Badges extends ModuleBadgesController {
  _Badges(super.ref) {
    state = {
      'nick': [_level('Lv 8')],
      'ada': [_level('Lv 12')],
      'bob': [_level('Lv 5')],
    };
  }

  @override
  void request(String id) {}
}

void main() {
  setUpAll(loadRealFonts);

  for (final brightness in Brightness.values) {
    for (final (label, width) in [('pane', 236.0), ('phone', 390.0)]) {
      testWidgets('member rows $label ${brightness.name}', (tester) async {
        tester.view.physicalSize = Size(width + 40, 220);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final tokens = brightness == Brightness.dark
            ? AppTokens.dark
            : AppTokens.light;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              moduleMemberBadgesShownProvider.overrideWithValue(true),
              liveEventsProvider.overrideWithValue(
                const Stream<api.ServerEvent>.empty(),
              ),
              moduleBadgesProvider.overrideWith((ref) => _Badges(ref)),
            ],
            child: MaterialApp(
              theme: buildTheme(brightness, tokens),
              home: Scaffold(
                backgroundColor: tokens.surfaceSunken,
                body: Align(
                  alignment: Alignment.topLeft,
                  child: RepaintBoundary(
                    key: snapshotBoundary,
                    child: ColoredBox(
                      color: tokens.surfaceSunken,
                      child: SizedBox(
                        width: width,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MemberRow(
                              profile: _member(
                                'nick',
                                'Nick',
                                roles: ['Admin'],
                              ),
                              isSelf: true,
                            ),
                            MemberRow(
                              profile: _member('ada', 'Ada Lovelace'),
                              isSelf: false,
                            ),
                            MemberRow(
                              profile: _member(
                                'bob',
                                'Roberta the Long Named',
                                roles: ['Administrator'],
                              ),
                              isSelf: false,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        await tester.pump();

        await writeSnapshot(
          tester,
          'member-row-badges-$label-${brightness.name}',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
