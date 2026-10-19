// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The row menus' one Notifications entry: each choice, picked through the
/// submenu, changes the stored setting, on a wide window and on a phone sheet.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/settings/providers/notification_schedule_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/fake_api.dart';
import '../../ui_snapshot_support.dart' show loadRealFonts;

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

const _channel = Channel(
  id: 'c1',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class _Fixture {
  _Fixture({List<String> allowedChannels = const []}) {
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          final path = request.url.path;
          if (path.startsWith('/notifications/schedule/allowed-channels/')) {
            requests.add('${request.method} $path');
            return http.Response('', 204);
          }
          if (path == '/notifications/schedule') {
            return _json({
              'schedule': {
                'timezone': 'UTC',
                'days': <Object>[],
                'off_hours_mode': 'mentions',
                'snooze_until': null,
                'allowed_user_ids': <String>[],
                'allowed_channel_ids': allowedChannels,
              },
            });
          }
          if (path.startsWith('/notification-preferences/channels/')) {
            if (request.method == 'DELETE') {
              requests.add('DELETE $path');
              return http.Response('', 204);
            }
            requests.add('${request.method} $path ${request.body}');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return _json({
              'channel_id': request.url.pathSegments.last,
              'preference': body['preference'],
            });
          }
          return _json(const <Object>[]);
        }),
      ],
    );
    container.listen(notificationScheduleProvider, (_, _) {});
  }

  late final ProviderContainer container;
  final requests = <String>[];

  api.NotificationPreference? get stored =>
      container.read(channelNotificationOverridesProvider).overrideFor('c1');
}

Future<void> _pumpRow(
  WidgetTester tester,
  _Fixture fixture, {
  required double width,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(fixture.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ChannelCategorySections(
            channels: const [_channel],
            categories: const [],
            selectedId: null,
            onReorder: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
}

Future<void> _openRowMenu(WidgetTester tester, {required bool phone}) async {
  if (phone) {
    await tester.longPress(find.text('general'));
  } else {
    await tester.tapAt(
      tester.getCenter(find.text('general')),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
  }
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(find.text('Notifications'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (name, width, phone) in [
    ('wide window', 1000.0, false),
    ('phone sheet', 390.0, true),
  ]) {
    group('on a $name', () {
      testWidgets('the menu has one Notifications entry, no loose choices', (
        tester,
      ) async {
        final fixture = _Fixture();
        await _pumpRow(tester, fixture, width: width);
        await _openRowMenu(tester, phone: phone);

        expect(find.text('Notifications'), findsOneWidget);
        expect(find.text('Mute channel'), findsNothing);
        expect(find.text('Mentions only'), findsNothing);
        expect(find.text('Notify me off hours'), findsNothing);
        expect(find.text('Default'), findsOneWidget);
      });

      testWidgets('Mute channel stores nothing', (tester) async {
        final fixture = _Fixture();
        await _pumpRow(tester, fixture, width: width);
        await _openRowMenu(tester, phone: phone);
        await _choose(tester, 'Mute channel');

        expect(fixture.stored, api.NotificationPreference.nothing);
        expect(fixture.requests, hasLength(1));
        expect(fixture.requests.single, contains('"nothing"'));
      });

      testWidgets('Mentions only stores mentions', (tester) async {
        final fixture = _Fixture();
        await _pumpRow(tester, fixture, width: width);
        await _openRowMenu(tester, phone: phone);
        await _choose(tester, 'Mentions only');

        expect(fixture.stored, api.NotificationPreference.mentions);
      });

      testWidgets('Notify me off hours allows the channel', (tester) async {
        final fixture = _Fixture();
        await _pumpRow(tester, fixture, width: width);
        await _openRowMenu(tester, phone: phone);
        await _choose(tester, 'Notify me off hours');

        expect(fixture.requests, [
          'PUT /notifications/schedule/allowed-channels/c1',
        ]);
      });

      testWidgets('an allowed channel is taken off the list again', (
        tester,
      ) async {
        final fixture = _Fixture(allowedChannels: const ['c1']);
        await _pumpRow(tester, fixture, width: width);
        await _openRowMenu(tester, phone: phone);
        await _choose(tester, 'Notify me off hours');

        expect(fixture.requests, [
          'DELETE /notifications/schedule/allowed-channels/c1',
        ]);
      });

      testWidgets('the entry names the current choice and a second pick '
          'of it clears it', (tester) async {
        final fixture = _Fixture();
        await _pumpRow(tester, fixture, width: width);
        await fixture.container
            .read(channelNotificationOverridesProvider.notifier)
            .mentionsOnly('c1');
        await tester.pump();
        await _openRowMenu(tester, phone: phone);

        expect(
          find.descendant(
            of: find.widgetWithText(AppMenuItem, 'Notifications'),
            matching: find.text('Mentions'),
          ),
          findsOneWidget,
        );
        final label = tester.renderObject<RenderParagraph>(
          find.text('Notifications'),
        );
        expect(label.didExceedMaxLines, isFalse, reason: 'name is not cut off');
        await _choose(tester, 'Mentions only');
        expect(fixture.stored, isNull);
      });
    });
  }

  testWidgets('the entry opens from the keyboard and a choice is picked '
      'with Enter', (tester) async {
    final fixture = _Fixture();
    await _pumpRow(tester, fixture, width: 1000);
    await _openRowMenu(tester, phone: false);

    final entry = find.widgetWithText(AppMenuItem, 'Notifications');
    final semantics = tester.getSemantics(entry);
    expect(semantics.label, 'Notifications\nDefault');
    expect(semantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    for (var i = 0; i < 4 && fixture.stored == null; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      if (find.text('Mute channel').evaluate().isEmpty) break;
    }
    expect(fixture.requests, isNotEmpty, reason: 'a key press chose an entry');
  });
}
