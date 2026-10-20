// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A muted channel's rail row: the bell-off glyph, and nothing else.
///
/// `AppListRow.unread` used to stay exactly what `cursor > lastReadSeq` said
/// regardless of mute, on the reading that muting is about interruptions and
/// never about read state. Half of that still holds - the channel row behind
/// the widget is untouched either way - but the owner settled the other half
/// the other way in
/// `docs/decisions/0049-per-channel-notification-behaviour.md`: a muted
/// channel shows nothing at all, so the flag the bold weight and the screen
/// reader key off is false while the read state behind it is not.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Channel _channel(
  String id,
  String name, {
  int cursor = 0,
  int lastReadSeq = 0,
}) => Channel(
  id: id,
  name: name,
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: cursor,
  lastReadSeq: lastReadSeq,
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

/// Answers the real PUT the mute call sends, so
/// [ChannelNotificationOverridesController.mute] round-trips exactly as it
/// does against the server rather than needing a seam to fake its state.
ProviderContainer _container() => ProviderContainer(
  overrides: [
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    mockApiOverride((request) async {
      if (request.url.path.startsWith('/notification-preferences/channels/') &&
          request.method == 'PUT') {
        final channelId = request.url.pathSegments.last;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({
          'channel_id': channelId,
          'preference': body['preference'],
        });
      }
      return _json(const <Object>[]);
    }),
  ],
);

Widget _harness(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the menu marks the chosen notification mode with a check, '
      'not only a tint', (tester) async {
    final container = _container();
    await tester.pumpWidget(
      _harness(
        container,
        ChannelCategorySections(
          channels: [_channel('c1', 'general')],
          categories: const [],
          selectedId: null,
          onReorder: (_) {},
        ),
      ),
    );
    await tester.pump();
    await container
        .read(channelNotificationOverridesProvider.notifier)
        .mentionsOnly('c1');
    await tester.pump();

    await tester.tapAt(
      tester.getCenter(find.text('general')),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.widgetWithText(AppMenuItem, 'Notifications'),
        matching: find.text('Mentions'),
      ),
      findsOneWidget,
      reason: 'the entry shows the current choice',
    );
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();

    Finder checkIn(String label) => find.descendant(
      of: find.widgetWithText(AppMenuItem, label),
      matching: find.byIcon(AppIcons.check),
    );
    expect(checkIn('Mentions only'), findsOneWidget);
    expect(checkIn('Mute channel'), findsNothing);

    for (final label in [
      'Mute channel',
      'Mentions only',
      'Notify me off hours',
    ]) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.widgetWithText(AppMenuItem, label),
          matching: find.text(label),
        ),
      );
      final full = TextPainter(
        text: paragraph.text,
        textDirection: TextDirection.ltr,
      )..layout();
      expect(
        paragraph.size.width,
        greaterThanOrEqualTo(full.width - 0.5),
        reason: '$label is cut off by the menu width',
      );
    }
    container.dispose();
  });

  testWidgets('an unmuted channel carries no bell-off glyph', (tester) async {
    final container = _container();
    await tester.pumpWidget(
      _harness(
        container,
        ChannelCategorySections(
          channels: [_channel('c1', 'general')],
          categories: const [],
          selectedId: null,
          onReorder: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(AppIcons.notificationsOff), findsNothing);
    container.dispose();
  });

  testWidgets('muting a channel shows the bell-off glyph on its own row', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(
      _harness(
        container,
        ChannelCategorySections(
          channels: [_channel('c1', 'general')],
          categories: const [],
          selectedId: null,
          onReorder: (_) {},
        ),
      ),
    );
    await tester.pump();

    await container
        .read(channelNotificationOverridesProvider.notifier)
        .mute('c1');
    await tester.pump();

    expect(find.byIcon(AppIcons.notificationsOff), findsOneWidget);
    container.dispose();
  });

  testWidgets(
    'a muted, unread channel reports itself read to AppListRow, while the '
    'channel row behind it stays unread',
    (tester) async {
      final container = _container();
      final channel = _channel('c1', 'general', cursor: 5, lastReadSeq: 2);
      await tester.pumpWidget(
        _harness(
          container,
          ChannelCategorySections(
            channels: [channel],
            categories: const [],
            selectedId: null,
            onReorder: (_) {},
          ),
        ),
      );
      await tester.pump();

      await container
          .read(channelNotificationOverridesProvider.notifier)
          .mute('c1');
      await tester.pump();

      final row = tester.widget<AppListRow>(find.byType(AppListRow));
      expect(
        row.unread,
        isFalse,
        reason: 'mute is nothing at all, so the bold weight goes too',
      );
      expect(row.muted, isTrue);
      expect(
        channel.cursor > channel.lastReadSeq,
        isTrue,
        reason:
            'hiding the indicator must not have marked anything read: the '
            'unread divider and the read marker still read this row',
      );
      container.dispose();
    },
  );

  testWidgets('clearing a mute removes the bell-off glyph again', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(
      _harness(
        container,
        ChannelCategorySections(
          channels: [_channel('c1', 'general')],
          categories: const [],
          selectedId: null,
          onReorder: (_) {},
        ),
      ),
    );
    await tester.pump();
    final notifier = container.read(
      channelNotificationOverridesProvider.notifier,
    );
    await notifier.mute('c1');
    await tester.pump();
    expect(find.byIcon(AppIcons.notificationsOff), findsOneWidget);

    await notifier.clear('c1');
    await tester.pump();

    expect(find.byIcon(AppIcons.notificationsOff), findsNothing);
    container.dispose();
  });
}
