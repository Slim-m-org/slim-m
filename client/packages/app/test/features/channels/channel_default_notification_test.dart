// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel's default notification level: what its rail row and the account
/// badge draw, how the row menu words it, and the two controls that set it.
/// A member's own choice always wins over the default.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account_unread.dart';
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/channels/widgets/create_channel_sheet.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_rules.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/fake_api.dart';
import 'channel_management_harness.dart' hide channel;
import 'channel_management_harness.dart' as h show channel;

const _everything = api.NotificationPreference.everything;
const _mentions = api.NotificationPreference.mentions;
const _nothing = api.NotificationPreference.nothing;

Channel _unread(String? level) => Channel(
  id: 'c1',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 3,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  defaultNotification: level,
  isPersonalSpace: false,
);

void main() {
  group('the rule', () {
    test(
      'a default applies only where the member has no choice of their own',
      () {
        final channel = _unread('nothing');
        expect(
          const ChannelNotificationOverridesState().effectiveFor(channel),
          _nothing,
        );
        const own = ChannelNotificationOverridesState(
          byChannel: {'c1': _mentions},
        );
        expect(own.effectiveFor(channel), _mentions);
      },
    );

    test('everything and an absent value both mean no default', () {
      const state = ChannelNotificationOverridesState();
      expect(state.effectiveFor(_unread(null)), isNull);
      expect(state.effectiveFor(_unread('everything')), isNull);
    });

    test(
      'a muted default lights no unread badge, an own choice brings it back',
      () {
        final channels = [_unread('nothing')];
        expect(
          countUnread(
            channels,
            const ChannelNotificationOverridesState(),
          ).channels,
          0,
        );
        const optedIn = ChannelNotificationOverridesState(
          byChannel: {'c1': _everything},
        );
        expect(countUnread(channels, optedIn).channels, 1);
      },
    );

    test('a default only narrows the account preference', () {
      expect(stricterPreference(_mentions, _nothing), _nothing);
      expect(stricterPreference(_nothing, _everything), _nothing);
      expect(stricterPreference(null, _mentions), _mentions);
      expect(stricterPreference(null, null), isNull);
    });
  });

  group('the row menu', () {
    Future<void> openMenu(
      WidgetTester tester,
      ProviderContainer container,
      String? level,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: ChannelCategorySections(
                channels: [
                  h.channel('c1', 'general', defaultNotification: level),
                ],
                categories: const [],
                selectedId: null,
                onReorder: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tapAt(
        tester.getCenter(find.text('general')),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    ProviderContainer container() => ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
        mockApiOverride((request) async => http.Response('[]', 200)),
      ],
    );

    Finder checkIn(String label) => find.descendant(
      of: find.widgetWithText(AppMenuItem, label),
      matching: find.byIcon(AppIcons.check),
    );

    testWidgets('names the default and checks it until the member chooses', (
      tester,
    ) async {
      await openMenu(tester, container(), 'mentions');
      expect(find.text('Default'), findsOneWidget);
      await tester.tap(find.text('Notifications'));
      await tester.pumpAndSettle();
      expect(find.text('Default (Mentions)'), findsOneWidget);
      expect(checkIn('Default (Mentions)'), findsOneWidget);
      expect(checkIn('Mentions only'), findsNothing);
    });

    testWidgets('offers no default entry on a channel without one', (
      tester,
    ) async {
      await openMenu(tester, container(), null);
      expect(find.textContaining('Default ('), findsNothing);
    });
  });

  testWidgets('channel settings saves the chosen default', (tester) async {
    final patches = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      harness(
        ChannelCategorySections(
          channels: [h.channel('c1', 'general')],
          categories: const [],
          selectedId: null,
          canManage: true,
          onReorder: (_) {},
        ),
        handler: (request) {
          if (request.method == 'PATCH') {
            patches.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({
                'id': 'c1',
                'name': 'general',
                'kind': 'text',
                'created_at': 0,
                'default_notification': 'mentions',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200);
        },
      ),
    );
    await tester.tap(find.bySemanticsLabel('Manage general'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Channel settings...'));
    await tester.pumpAndSettle();

    expect(find.text('All messages'), findsOneWidget);
    await tester.tap(find.text('Default notifications'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mentions only'));
    await tester.pumpAndSettle();

    expect(patches, [
      {'default_notification': 'mentions'},
    ]);
    expect(find.text('Mentions only'), findsOneWidget);
  });

  group('the create sheet', () {
    Future<Map<String, dynamic>> submit(
      WidgetTester tester, {
      String? choose,
    }) async {
      late Map<String, dynamic> body;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiProvider.overrideWith(
              (ref) => testApi((request) async {
                body = jsonDecode(request.body) as Map<String, dynamic>;
                return http.Response('{"error":"nope"}', 400);
              }, session: api.SessionStore(tokens: tokens)),
            ),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showCreateChannelSheet(context, initialKind: 'text'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (choose != null) {
        await tester.tap(find.text('Default notifications'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(choose));
        await tester.pumpAndSettle();
      }
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is AppInput && w.placeholder == 'Channel name',
        ),
        'quiet',
      );
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('Create channel'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      return body;
    }

    testWidgets('sends the chosen default', (tester) async {
      expect(
        (await submit(tester, choose: 'Muted'))['default_notification'],
        'nothing',
      );
    });

    testWidgets('sends none when left alone', (tester) async {
      expect(await submit(tester), isNot(contains('default_notification')));
    });
  });
}
