// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Module slots as they land in the app: a profile section on a card and
/// badges in the member list, at a pane width and a phone width, in both
/// themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/module_profile_slots.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/features/members/widgets/module_profile_slots.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/fake_api.dart';
import 'ui_snapshot_support.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _viewports = {'pane': 236.0, 'phone': 390.0};

const _longName = 'Level progress for the whole season so far';

final _sections = [
  api.ModuleProfileSection(
    moduleId: 'xp',
    name: 'level',
    title: 'Level',
    item: api.ModuleSlotItem.parse({
      'nodes': [
        {'type': 'text', 'text': 'Level 12', 'tone': 'accent'},
        {'type': 'progress', 'value': 640, 'max': 1000, 'label': 'XP'},
        {
          'type': 'row',
          'children': [
            {'type': 'badge', 'text': 'Veteran', 'icon': 'list'},
            {'type': 'badge', 'text': 'Admin', 'tone': 'accent'},
            {'type': 'icon', 'name': 'play'},
          ],
        },
      ],
    }),
  ),
  api.ModuleProfileSection(
    moduleId: 'seasons',
    name: 'season',
    title: 'Season',
    item: api.ModuleSlotItem.parse({
      'nodes': [
        {
          'type': 'stack',
          'children': [
            {'type': 'text', 'text': _longName, 'tone': 'muted'},
            {'type': 'progress', 'value': 3, 'max': 12},
          ],
        },
      ],
    }),
  ),
  const api.ModuleProfileSection(
    moduleId: 'plain',
    name: 'note',
    title: 'Note',
    item: api.ModuleSlotItem(fallback: 'No ranking yet'),
  ),
];

Future<void> _theme(
  WidgetTester tester,
  double width,
  bool dark,
  Widget child,
) {
  tester.view.physicalSize = Size(width + 32, 520);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return tester.pumpWidget(child);
}

void main() {
  setUpAll(loadRealFonts);

  for (final MapEntry(key: name, value: width) in _viewports.entries) {
    for (final dark in [false, true]) {
      final theme = dark ? 'dark' : 'light';
      final tokens = dark ? AppTokens.dark : AppTokens.light;

      testWidgets('profile sections, $name, $theme', (tester) async {
        await _theme(
          tester,
          width,
          dark,
          ProviderScope(
            overrides: [
              moduleProfileSlotsProvider.overrideWith((ref, _) => _sections),
            ],
            child: MaterialApp(
              theme: buildTheme(
                dark ? Brightness.dark : Brightness.light,
                tokens,
              ),
              home: RepaintBoundary(
                key: snapshotBoundary,
                child: Scaffold(
                  backgroundColor: tokens.surfaceRaised,
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: const ModuleProfileSlots('u1'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Level 12'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await writeSnapshot(tester, 'module_slots_profile_${name}_$theme');
      });

      testWidgets('member list badges, $name, $theme', (tester) async {
        final members = [
          for (final (id, n) in const [
            ('a', 'Anna'),
            ('b', 'Bo with a very long display name'),
            ('c', 'Cleo'),
          ])
            api.UserProfile(
              id: id,
              username: id,
              displayName: n,
              createdAt: 0,
              roles: id == 'c' ? const ['Moderator'] : const [],
            ),
        ];
        final events = StreamController<api.ServerEvent>.broadcast();
        addTearDown(events.close);
        final badgeJson = {
          'a': [
            {'text': 'LV 12', 'tone': 'accent'},
          ],
          'b': [
            {'text': 'Veteran of the season'},
            {'text': 'Streak 4'},
            {'text': 'Third'},
          ],
          'c': [
            {'text': 'Admin', 'tone': 'accent'},
            {'text': 'Streak 4', 'tone': 'muted'},
          ],
        };
        await _theme(
          tester,
          width,
          dark,
          ProviderScope(
            overrides: [
              sessionProvider.overrideWithValue(
                api.SessionStore(tokens: _tokens),
              ),
              liveEventsProvider.overrideWithValue(events.stream),
              membersProvider.overrideWith((ref) async => members),
              channelMembersProvider.overrideWith((ref, _) async => members),
              mockApiOverride((request) async {
                final path = request.url.path;
                if (path == '/space/dock/slots/badges') {
                  return http.Response(
                    jsonEncode({
                      'badges': {
                        for (final e in badgeJson.entries)
                          e.key: [
                            for (final b in e.value)
                              {
                                'module_id': 'xp',
                                'name': 'level',
                                'nodes': [
                                  {'type': 'badge', ...b},
                                ],
                              },
                          ],
                      },
                    }),
                    200,
                  );
                }
                if (path == '/me') {
                  return http.Response(
                    jsonEncode({
                      'id': 'self',
                      'username': 'self',
                      'display_name': 'Self',
                      'created_at': 0,
                      'permissions': 0,
                    }),
                    200,
                  );
                }
                return http.Response('[]', 200);
              }),
            ],
            child: MaterialApp(
              theme: buildTheme(
                dark ? Brightness.dark : Brightness.light,
                tokens,
              ),
              home: RepaintBoundary(
                key: snapshotBoundary,
                child: Scaffold(
                  backgroundColor: tokens.surfaceSunken,
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: const AppMemberPane(channelId: 'c1'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('LV 12'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await writeSnapshot(tester, 'module_slots_roster_${name}_$theme');
      });
    }
  }
}
