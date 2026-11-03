// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member list as the end drawer of the real shell below the width that
/// docks it, with module badges on, in the dark and light themes and the
/// seasonal halloween one. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/module_badges.dart';
import 'package:slimm_app/src/features/modules/providers/module_display_settings.dart';

import '../ui_snapshot_support.dart';

api.ModuleBadge _badge(String text, String tone) => api.ModuleBadge(
  moduleId: 'xp',
  name: 'level',
  item: api.ModuleSlotItem.parse({
    'nodes': [
      {'type': 'badge', 'text': text, 'tone': tone, 'icon': 'sparkles'},
    ],
  }),
);

class _Badges extends ModuleBadgesController {
  _Badges(super.ref) {
    state = {
      'user-nick': [_badge('Lv 8', 'accent')],
      'user-ada': [_badge('Lv 12', 'accent'), _badge('Streak 4', 'muted')],
      'user-long-name': [_badge('Veteran of the season', 'accent')],
    };
  }

  @override
  void request(String id) {}
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in const ['phone-portrait', 'compact-599']) {
    testWidgets('member drawer badges at $viewport', (tester) async {
      await renderSurfaceThemes(
        tester,
        '/channels/c-general',
        viewport,
        const ['dark', 'light', 'halloween'],
        (t) => 'member-drawer-badges-$viewport-$t',
        overrides: [
          moduleBadgesProvider.overrideWith((ref) => _Badges(ref)),
          moduleMemberBadgesShownProvider.overrideWithValue(true),
        ],
        afterSettle: (tester) async {
          await tester.tap(find.byTooltip('Members'));
          await tester.pump(const Duration(milliseconds: 400));
        },
      );
    });
  }
}
